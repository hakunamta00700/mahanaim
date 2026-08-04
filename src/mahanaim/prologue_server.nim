## Prologue application/server lifecycle bridge.
##
## The Prologue router is deliberately used only as a transport entry point.
## A catch-all route converts the native request once and delegates matching,
## middleware, security, errors, and lifecycle semantics to Mahanaim's core.

import std/[asyncdispatch, httpcore, options]
when defined(windows):
  import std/asynchttpserver
import prologue/core/application as prologueApplication
import ./application
import ./prologue_adapter
import ./response_policy
import ./router
import ./websocket_adapter

type
  PrologueServer* = ref object
    ## Keep both owners visible so embedding applications can configure the
    ## Prologue server while retaining the framework-neutral Application.
    framework*: Application
    server*: prologueApplication.Prologue
    when defined(windows):
      ## Prologue 0.6.8 keeps its AsyncHttpServer private. On Windows the
      ## native request type is stdlib-compatible, so this owned transport
      ## lets the adapter expose deterministic close and ephemeral-port
      ## lifecycle semantics without reaching into private Prologue fields.
      transport*: AsyncHttpServer
      closed*: bool

proc bridgeHandler(app: Application): prologueApplication.HandlerAsync =
  ## Adapt one Prologue Context without duplicating route registration.
  result = proc(ctx: prologueApplication.Context) {.async, gcsafe.} =
    let frameworkRequest = toFrameworkRequest(ctx.request)
    ## Both Prologue backends use the same route registry. Only the native
    ## request/socket handoff differs, so the protocol policy remains here.
    let websocketRoute = app.router.findWebSocket(frameworkRequest.path)
    if websocketRoute.isSome:
      if frameworkRequest.httpMethod != "GET" or
         not isWebSocketUpgrade(frameworkRequest):
        await ctx.request.respond(Http426, "WebSocket upgrade required")
        ## Prologue's central response phase must not write a second response
        ## after an adapter has already completed the socket.
        ctx.handled = true
      else:
        ## Overload resolution selects stdlib or Beast/httpx ownership.
        await serveWebSocket(ctx.request.nativeRequest, frameworkRequest,
          websocketRoute.get())
        ## The WebSocket adapter owns this connection after the 101 handshake.
        ctx.handled = true
      return
    let frameworkResponse = negotiateResponse(frameworkRequest,
      await app.dispatch(frameworkRequest))
    # Populate Prologue's response object and let its normal central response
    # phase write to the socket. This also keeps mocking contexts socket-free.
    ctx.response.code = frameworkResponse.status
    ctx.response.body = frameworkResponse.body
    ctx.response.headers = toPrologueHeaders(frameworkResponse)

proc newPrologueServer*(app: Application,
                        settings = prologueApplication.newSettings()): PrologueServer =
  ## Build an adapter without starting sockets; this makes server setup
  ## inspectable and deterministic in tests and embedding applications.
  new(result)
  result.framework = app
  result.server = prologueApplication.newApp(settings = settings)
  when defined(windows):
    result.transport = newAsyncHttpServer()
    result.closed = false
  # Register root and wildcard entries because Prologue treats the root as a
  # distinct route while Mahanaim's dispatcher owns the final route decision.
  result.server.all("/", bridgeHandler(app))
  result.server.all("/*", bridgeHandler(app))

proc startup*(server: PrologueServer) =
  ## Start framework lifecycle hooks exactly once before serving requests.
  server.framework.startup()

proc shutdown*(server: PrologueServer) =
  ## Expose an embedding-safe shutdown hook for graceful server integration.
  server.framework.shutdown()

when defined(windows):
  proc close*(server: PrologueServer) =
    ## Close only the socket owned by this adapter and make repeated cleanup
    ## safe for tests, embedding hosts, and error paths.
    if server.closed:
      return
    server.closed = true
    server.transport.close()
    server.shutdown()

  proc boundPort*(server: PrologueServer): Port =
    ## Expose the bound ephemeral port without exposing transport internals.
    server.transport.getPort()

proc runAsync*(server: PrologueServer): Future[void] {.async.} =
  ## Async counterpart for applications that own their event loop.
  when defined(windows):
    ## Keep Prologue's router/context pipeline, but move socket creation to
    ## the adapter-owned server so close() can deterministically interrupt
    ## the accept loop. This path is limited to the stdlib-native backend;
    ## the Beast backend still delegates to Prologue until its ownership API
    ## is available.
    server.server.gScope.router.compress()
    server.server.execStartupEvent()
    server.startup()
    let callback = proc(request: asynchttpserver.Request): Future[void]
        {.async, gcsafe.} =
      await server.server.handleRequest(request, prologueApplication.Context)
    try:
      await server.transport.serve(server.server.gScope.settings.port,
        callback, server.server.gScope.settings.address)
    except OSError:
      if not server.closed:
        raise
  else:
    server.startup()
    await server.server.runAsync()

proc run*(server: PrologueServer) =
  ## Synchronous Prologue server entry point.
  when defined(windows):
    waitFor server.runAsync()
  else:
    server.startup()
    server.server.run()

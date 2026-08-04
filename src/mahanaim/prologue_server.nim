## Prologue application/server lifecycle bridge.
##
## The Prologue router is deliberately used only as a transport entry point.
## A catch-all route converts the native request once and delegates matching,
## middleware, security, errors, and lifecycle semantics to Mahanaim's core.

import std/[asyncdispatch, httpcore, options]
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

proc bridgeHandler(app: Application): prologueApplication.HandlerAsync =
  ## Adapt one Prologue Context without duplicating route registration.
  result = proc(ctx: prologueApplication.Context) {.async, gcsafe.} =
    let frameworkRequest = toFrameworkRequest(ctx.request)
    when defined(windows):
      ## Prologue's Windows/native backend exposes the same AsyncSocket owned
      ## by the request. Transfer ownership to the shared WebSocket adapter
      ## before Prologue writes a normal HTTP response for the context.
      let websocketRoute = app.router.findWebSocket(frameworkRequest.path)
      if websocketRoute.isSome:
        if frameworkRequest.httpMethod != "GET" or
           not isWebSocketUpgrade(frameworkRequest):
          await ctx.request.respond(Http426, "WebSocket upgrade required")
        else:
          await serveWebSocket(ctx.request.nativeRequest, frameworkRequest,
            websocketRoute.get())
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

proc run*(server: PrologueServer) =
  ## Synchronous Prologue server entry point.
  server.startup()
  server.server.run()

proc runAsync*(server: PrologueServer): Future[void] {.async.} =
  ## Async counterpart for applications that own their event loop.
  server.startup()
  await server.server.runAsync()

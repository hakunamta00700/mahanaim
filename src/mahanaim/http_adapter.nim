## Standard-library HTTP adapter.
##
## The core application deliberately does not depend on a concrete server. This
## adapter is the first network boundary: it translates Nim's async HTTP server
## request into Mahanaim's framework-neutral Request and writes Response back.
## A future Prologue adapter can implement the same two translation functions.

import std/[asynchttpserver, asyncdispatch, asyncnet, httpcore, nativesockets, strutils,
            options, tables, uri]
import ./application
import ./core
import ./router
import ./websocket_adapter

type
  NetworkServer* = ref object
    ## Owns one async server and one application instance.
    app*: Application
    server*: AsyncHttpServer
    host*: string
    port*: Port
    closed*: bool

proc copyHeaders*(headers: HttpHeaders): Table[string, string] =
  ## Normalize header names once at the adapter boundary. Nim's HttpHeaders
  ## iterator yields comma-separated field values as repeated entries, so
  ## append them instead of retaining only the final value. In particular,
  ## browser Accept headers commonly end with application/signed-exchange;
  ## dropping the earlier text/html value would incorrectly produce HTTP 406.
  result = initTable[string, string]()
  for key, value in headers:
    let normalized = key.toLowerAscii()
    if result.hasKey(normalized):
      result[normalized].add(", " & value)
    else:
      result[normalized] = value

proc parseCookies(headerValue: string): Table[string, string] =
  ## Parse the simple Cookie grammar needed by the core request object.
  ## Quoted cookie values and repeated-cookie policy can be added here later
  ## without changing handlers or the Application dispatcher.
  result = initTable[string, string]()
  for item in headerValue.split(';'):
    let pieces = item.split('=', maxsplit = 1)
    if pieces.len == 2:
      result[pieces[0].strip()] = pieces[1].strip()

proc toFrameworkRequest*(request: asynchttpserver.Request): core.Request =
  ## Convert wire data into the framework-neutral request snapshot.
  result = newRequest($request.reqMethod, request.url.path, request.body)
  ## Capture the direct peer at the network boundary. The security layer can
  ## therefore accept forwarded scheme/host only from an explicit proxy list.
  result.remoteAddress = request.client.getPeerAddr()[0]
  result.query = initTable[string, string]()
  for key, value in decodeQuery(request.url.query):
    result.query[key] = value
  result.headers = copyHeaders(request.headers)
  result.cookies = initTable[string, string]()
  if result.headers.hasKey("cookie"):
    result.cookies = parseCookies(result.headers["cookie"])

proc toHttpHeaders*(response: Response): HttpHeaders =
  ## Convert response headers while preserving the core's explicit values.
  result = newHttpHeaders()
  for key, value in response.headers:
    result[key] = value

proc respondChunked(request: asynchttpserver.Request,
                    response: Response): Future[void] {.async, gcsafe.} =
  ## `AsyncHttpServer.respond` always emits one buffered Content-Length body.
  ## Write the framing here so stream/SSE representations have observable wire
  ## semantics while the core response remains transport-neutral.
  let headers = toHttpHeaders(response)
  if headers.hasKey("content-length"):
    headers.del("content-length")
  headers["transfer-encoding"] = "chunked"
  var headerBlock = "HTTP/1.1 " & $response.status & "\c\L"
  for key, value in headers:
    headerBlock.add(key & ": " & value & "\c\L")
  headerBlock.add("\c\L")
  let clientFd = AsyncFD(request.client.getFd())
  await clientFd.send(headerBlock)

  const chunkSize = 4096
  var offset = 0
  while offset < response.body.len:
    let length = min(chunkSize, response.body.len - offset)
    await clientFd.send(toHex(length) & "\c\L")
    await clientFd.send(response.body[offset ..< offset + length])
    await clientFd.send("\c\L")
    offset += length
  await clientFd.send("0\c\L\c\L")

proc handleRequest(network: NetworkServer,
                   request: asynchttpserver.Request): Future[void] {.async, gcsafe.} =
  ## Keep the network callback tiny: translate, dispatch, translate back.
  let frameworkRequest = toFrameworkRequest(request)
  let websocketRoute = network.app.router.findWebSocket(frameworkRequest.path)
  if websocketRoute.isSome:
    if frameworkRequest.httpMethod != "GET" or
         not isWebSocketUpgrade(frameworkRequest):
      await request.respond(Http426, "WebSocket upgrade required")
    else:
      ## AsyncHttpServer remains the parent owner of this request socket. The
      ## WebSocket session closes its protocol, then the parent closes the FD.
      await serveWebSocket(request, frameworkRequest, websocketRoute.get(),
        closeOnSession = false)
      request.headers["connection"] = "close"
    return
  ## Application.dispatch already resolves Accept variants. Keeping transport
  ## serialization here avoids a second policy decision at the wire boundary.
  let response = await network.app.dispatch(frameworkRequest)
  if response.representation in {rrStream, rrServerSentEvents}:
    await respondChunked(request, response)
  else:
    await request.respond(response.status, response.body, toHttpHeaders(response))

proc newNetworkServer*(app: Application, host = "127.0.0.1",
                       port = 8000): NetworkServer =
  ## Construct without binding. Tests can choose an ephemeral port later.
  NetworkServer(app: app, server: newAsyncHttpServer(), host: host,
                port: Port(port), closed: false)

proc serve*(network: NetworkServer): Future[void] {.async.} =
  ## Bind and serve until close() is called. Startup hooks run after binding.
  network.app.startup()
  let callback = proc(request: asynchttpserver.Request): Future[void] {.async, gcsafe.} =
    await handleRequest(network, request)
  try:
    await network.server.serve(network.port, callback, network.host)
  except OSError:
    ## AsyncHttpServer reports socket cancellation as OSError when close()
    ## interrupts serve().  That is expected during an owned graceful stop;
    ## unexpected I/O failures still propagate to the embedding application.
    if not network.closed:
      raise

proc close*(network: NetworkServer) =
  ## Close the socket and run shutdown hooks exactly once.
  if network.closed:
    return
  network.closed = true
  network.server.close()
  network.app.shutdown()

proc boundPort*(network: NetworkServer): Port =
  ## Expose the actual port for ephemeral-port tests and embedding hosts.
  network.server.getPort()

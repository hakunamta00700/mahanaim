## In-process test application and client.
##
## The client deliberately calls Application.dispatch rather than a private
## handler.  This gives contract tests the same routing, middleware, security,
## and error behavior that a network adapter invokes, without socket timing.

import std/[asyncdispatch, httpcore, options, strutils, tables, uri]
import ./application
import ./config
import ./core
import ./execution
import ./security
import ./database
import ./database_pool
import ./database_session
import ./router

type
  TestApplication* = Application

  TestClient* = ref object
    ## Cookie state belongs to one client, allowing isolated browser-like tests.
    app*: Application
    cookies*: Table[string, string]
    hasLastResponse*: bool
    lastResponse*: Response

  TestWebSocketClient* = ref object
    ## In-process WebSocket peer used by contract tests. It models the same
    ## message/session boundary as a network adapter, while keeping socket
    ## timing and platform-specific handshake code out of unit tests.
    app*: Application
    request*: Request
    session*: WebSocketSession
    connected*: bool
    closed*: bool
    handlerFuture*: Future[void]
    toServer: seq[WebSocketMessage]
    fromServer: seq[WebSocketMessage]
    toServerWaiter: Future[WebSocketMessage]
    fromServerWaiter: Future[WebSocketMessage]

  DatabaseTestFactory* = proc(): DatabaseAdapter {.gcsafe.}
  DatabaseTestCloser* = proc(adapter: DatabaseAdapter) {.gcsafe.}

  DatabaseTestFixture* = ref object
    ## A fixture owns only pool/session policy; the caller chooses SQLite,
    ## PostgreSQL, or a fake adapter through the backend-neutral factory.
    pool: DatabaseConnectionPool

proc newTestApplication*(config = defaultConfig(),
                         securityPolicy = defaultSecurityPolicy(),
                         executionPolicy = defaultExecutionPolicy()): TestApplication =
  ## Every test app owns fresh router, model, middleware, and lifecycle state.
  newApplication(config, securityPolicy, executionPolicy)

proc newTestClient*(app: Application): TestClient =
  ## Construct a deterministic client with no shared cookie jar.
  new(result)
  result.app = app
  result.cookies = initTable[string, string]()
  result.hasLastResponse = false
  result.lastResponse = newResponse(Http500)

proc newDatabaseTestFixture*(factory: DatabaseTestFactory,
                             closer: DatabaseTestCloser = nil): DatabaseTestFixture =
  ## One connection per fixture makes the transaction boundary deterministic;
  ## each operation is still isolated by a fresh DatabaseSession rollback.
  if factory.isNil:
    raise newException(ValueError, "Database test fixture requires a factory")
  new(result)
  result.pool = newDatabaseConnectionPool(factory, maxConnections = 1,
    closer = closer)

proc withTestDatabase*(fixture: DatabaseTestFixture,
                       operation: proc(adapter: DatabaseAdapter)) =
  ## Tests must never commit setup data into a shared fixture. Cleanup belongs
  ## here so assertion failures and raised application errors both rollback.
  if fixture.isNil or fixture.pool.isNil:
    raise newException(ValueError, "Database test fixture is required")
  let session = newDatabaseSession(fixture.pool, transactional = true)
  try:
    operation(session.adapter)
  finally:
    session.rollback()
    session.close()

proc close*(fixture: DatabaseTestFixture) =
  ## Close idle backend connections after the suite; active sessions still obey
  ## their own rollback/return contract before the pool closes.
  if not fixture.isNil and not fixture.pool.isNil:
    fixture.pool.close()

proc cookieHeader(client: TestClient): string =
  ## Serialize client cookies using the wire format consumed by adapters.
  var pairs: seq[string] = @[]
  for name, value in client.cookies:
    pairs.add(name & "=" & value)
  pairs.join("; ")

proc updateCookies(client: TestClient, response: Response) =
  ## Track the simple Set-Cookie form emitted by the core cookie helper.
  let header = response.header("set-cookie")
  if header.isNone:
    return
  let firstPart = header.get().split(';', maxsplit = 1)[0]
  let separator = firstPart.find('=')
  if separator > 0:
      client.cookies[firstPart[0 ..< separator]] = firstPart[separator + 1 .. ^1]

proc completedVoidFuture(): Future[void] =
  ## Adapter callbacks must always return a Future, even when a test transport
  ## can deliver a message synchronously. Keeping this detail here prevents
  ## each callback from inventing a different completion convention.
  result = newFuture[void]("test client completed callback")
  result.complete()

proc applyCookieHeader(request: var Request, headerValue: string) =
  ## Parse both client-managed and explicitly supplied cookie headers.
  for pair in headerValue.split(';'):
    let pieces = pair.split('=', maxsplit = 1)
    if pieces.len == 2:
      request.cookies[pieces[0].strip()] = pieces[1].strip()

proc buildFrameworkRequest(client: TestClient, httpMethod, path,
                           body: string,
                           headers: openArray[(string, string)]): Request =
  ## Build request snapshots in one place so HTTP and WebSocket test clients
  ## share query, header, and cookie behavior at the same adapter boundary.
  let parsed = parseUri(path)
  let requestPath = if parsed.path.len > 0: parsed.path else: "/"
  result = newRequest(httpMethod, requestPath, body)
  for key, value in decodeQuery(parsed.query):
    result.query[key] = value
  for header in headers:
    result.headers[header[0].toLowerAscii()] = header[1]
  let cookies = client.cookieHeader()
  let suppliedCookie = result.header("cookie")
  if suppliedCookie.isSome:
    result.applyCookieHeader(suppliedCookie.get())
  elif cookies.len > 0:
    result.headers["cookie"] = cookies
    result.applyCookieHeader(cookies)

proc requestInternal(client: TestClient, httpMethod, path, body: string,
                      headers: seq[(string, string)]): Future[Response] {.async.} =
  ## Build the same framework Request shape as a real HTTP adapter.
  let frameworkRequest = client.buildFrameworkRequest(httpMethod, path, body,
    headers)
  result = await client.app.dispatch(frameworkRequest)
  client.updateCookies(result)
  client.lastResponse = result
  client.hasLastResponse = true

proc request*(client: TestClient, httpMethod, path: string, body = "",
              headers: openArray[(string, string)] = []): Future[Response] =
  ## Copy borrowed header input before entering the async dispatch pipeline.
  var headerCopy: seq[(string, string)] = @[]
  for header in headers:
    headerCopy.add(header)
  client.requestInternal(httpMethod, path, body, headerCopy)

proc get*(client: TestClient, path: string,
          headers: openArray[(string, string)] = []): Future[Response] =
  ## Convenience method matching the most common test request.
  client.request("GET", path, headers = headers)

proc post*(client: TestClient, path: string; body = "",
           headers: openArray[(string, string)] = []): Future[Response] =
  ## POST keeps body and header construction visible in contract tests.
  client.request("POST", path, body, headers)

proc flushSseEvent(events: var seq[SseEvent], current: var SseEvent,
                   dataLines: var seq[string], hasField: var bool) =
  ## Finish one SSE record without a nested closure. A top-level helper keeps
  ## Nim's memory-safety rules explicit for the result sequence.
  if not hasField and dataLines.len == 0:
    return
  current.data = dataLines.join("\n")
  events.add(current)
  current = SseEvent(retryMs: -1)
  dataLines = @[]
  hasField = false

proc parseSseEvents*(body: string): seq[SseEvent] =
  ## Parse the wire representation emitted by `sseResponse`. This parser is
  ## deliberately independent of a server socket so tests can assert event
  ## fields and multiline data without duplicating protocol parsing logic.
  var current = SseEvent(retryMs: -1)
  var dataLines: seq[string] = @[]
  var hasField = false
  for rawLine in body.replace("\r\n", "\n").split('\n'):
    if rawLine.len == 0:
      result.flushSseEvent(current, dataLines, hasField)
      continue
    if rawLine[0] == ':':
      continue
    let separator = rawLine.find(':')
    let field = if separator >= 0: rawLine[0 ..< separator] else: rawLine
    var value = if separator >= 0: rawLine[separator + 1 .. ^1] else: ""
    if value.startsWith(" "):
      value = value[1 .. ^1]
    case field
    of "event":
      current.event = value
      hasField = true
    of "id":
      current.id = value
      hasField = true
    of "retry":
      current.retryMs = parseInt(value)
      hasField = true
    of "data":
      dataLines.add(value)
      hasField = true
    else:
      ## Unknown SSE fields are ignored by the browser protocol and therefore
      ## must not make a valid event fail parsing.
      discard
  result.flushSseEvent(current, dataLines, hasField)

proc getSseEventsInternal(client: TestClient, path: string,
                          headers: seq[(string, string)]):
                          Future[seq[SseEvent]] {.async.} =
  ## Provide a concise assertion API while retaining the normal TestClient
  ## response path for status/header checks.
  let response = await client.get(path, headers)
  if response.representation != rrServerSentEvents and
      not response.header("content-type").get("").startsWith("text/event-stream"):
    raise newException(ValueError, "TestClient response is not an SSE stream")
  return parseSseEvents(response.body)

proc getSseEvents*(client: TestClient, path: string,
                   headers: openArray[(string, string)] = []):
                   Future[seq[SseEvent]] =
  ## Copy borrowed header input before entering the asynchronous parser.
  var headerCopy: seq[(string, string)] = @[]
  for header in headers:
    headerCopy.add(header)
  client.getSseEventsInternal(path, headerCopy)

proc queueFromServer(client: TestWebSocketClient,
                     message: WebSocketMessage) =
  ## Deliver one server frame, waking exactly one pending test receive.
  if client.fromServerWaiter != nil and not client.fromServerWaiter.finished:
    let waiter = client.fromServerWaiter
    client.fromServerWaiter = nil
    waiter.complete(message)
  else:
    client.fromServer.add(message)

proc receiveForServer(client: TestWebSocketClient): Future[WebSocketMessage] =
  ## Server-side receive callback backed by the test client's outbound queue.
  if client.toServer.len > 0:
    result = newFuture[WebSocketMessage]("test websocket immediate receive")
    let message = client.toServer[0]
    client.toServer.delete(0)
    result.complete(message)
    return
  if client.closed:
    result = newFuture[WebSocketMessage]("test websocket closed receive")
    result.complete(closeWebSocketMessage())
    return
  if client.toServerWaiter != nil and not client.toServerWaiter.finished:
    raise newException(ValueError, "TestWebSocketClient supports one pending receive")
  client.toServerWaiter = newFuture[WebSocketMessage]("test websocket receive")
  client.toServerWaiter

proc closeForServer(client: TestWebSocketClient, code: int,
                    reason: string): Future[void] =
  ## Closing from the handler side is observable by the client and resolves a
  ## server receive so a handler cannot remain suspended after shutdown.
  if not client.closed:
    client.closed = true
    client.queueFromServer(closeWebSocketMessage(code, reason))
    if client.toServerWaiter != nil and not client.toServerWaiter.finished:
      let waiter = client.toServerWaiter
      client.toServerWaiter = nil
      waiter.complete(closeWebSocketMessage(code, reason))
  completedVoidFuture()

proc connectWebSocket*(client: TestClient, path: string,
                       headers: openArray[(string, string)] = []):
                       TestWebSocketClient =
  ## Start a WebSocket route against an in-process session. Route matching and
  ## path parameter extraction remain real router operations; only the socket
  ## transport is replaced by deterministic message queues.
  if client.isNil or client.app.isNil:
    raise newException(ValueError, "TestWebSocketClient requires an application")
  let request = client.buildFrameworkRequest("GET", path, "", headers)
  let route = client.app.router.findWebSocket(request.path)
  if route.isNone:
    raise newException(ValueError, "No WebSocket route matches " & request.path)
  new(result)
  result.app = client.app
  result.request = request
  result.request.pathParams = extractParams(route.get().pattern,
    request.path).get()
  result.connected = true
  let socket = result
  result.session = newWebSocketSession(
    proc(message: WebSocketMessage): Future[void] {.gcsafe.} =
      socket.queueFromServer(message)
      completedVoidFuture(),
    proc(): Future[WebSocketMessage] {.gcsafe.} =
      socket.receiveForServer(),
    proc(code: int, reason: string): Future[void] {.gcsafe.} =
      socket.closeForServer(code, reason))
  result.handlerFuture = route.get().handler(result.request, result.session)

proc send*(client: TestWebSocketClient,
           message: WebSocketMessage): Future[void] =
  ## Send a client frame to the route handler without exposing queue internals.
  if client.isNil or not client.connected or client.closed:
    raise newException(ValueError, "TestWebSocketClient is not connected")
  if client.toServerWaiter != nil and not client.toServerWaiter.finished:
    let waiter = client.toServerWaiter
    client.toServerWaiter = nil
    waiter.complete(message)
  else:
    client.toServer.add(message)
  completedVoidFuture()

proc receive*(client: TestWebSocketClient): Future[WebSocketMessage] =
  ## Receive the next frame emitted by the route handler.
  if client.isNil or not client.connected:
    raise newException(ValueError, "TestWebSocketClient is not connected")
  if client.fromServer.len > 0:
    result = newFuture[WebSocketMessage]("test websocket immediate client receive")
    let message = client.fromServer[0]
    client.fromServer.delete(0)
    result.complete(message)
    return
  if client.fromServerWaiter != nil and not client.fromServerWaiter.finished:
    raise newException(ValueError, "TestWebSocketClient supports one pending receive")
  client.fromServerWaiter = newFuture[WebSocketMessage]("test websocket client receive")
  client.fromServerWaiter

proc close*(client: TestWebSocketClient, code = 1000,
            reason = ""): Future[void] =
  ## Close the client side and wake any handler waiting for input.
  if client.isNil or client.closed:
    return completedVoidFuture()
  client.closed = true
  if client.toServerWaiter != nil and not client.toServerWaiter.finished:
    let waiter = client.toServerWaiter
    client.toServerWaiter = nil
    waiter.complete(closeWebSocketMessage(code, reason))
  client.session.close(code, reason)

proc wait*(client: TestWebSocketClient): Future[void] =
  ## Await handler completion to surface route failures in the test itself.
  if client.isNil or client.handlerFuture.isNil:
    raise newException(ValueError, "TestWebSocketClient has no handler")
  client.handlerFuture

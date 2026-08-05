## Core contracts for the Mahanaim request pipeline.
##
## This module intentionally contains no server or database implementation.
## Keeping the value objects and handler contracts small lets adapters (such as
## Prologue) evolve without leaking their types into application code.

import std/[asyncdispatch, httpcore, json, options, os, strutils, tables]
import std/concurrency/atomics
import ./database
import ./di
import ./tracing

type
  CancellationToken* = ref object
    ## Async handlers and taskpool workers share this flag. Atomic access
    ## makes cooperative cancellation defined across the event-loop/worker
    ## boundary; it still intentionally does not force-kill user code.
    cancelled*: Atomic[bool]

  Request* = object
    ## A framework-neutral HTTP request snapshot.
    ##
    ## The adapter layer is responsible for parsing the wire request and
    ## populating this object. Application handlers never need to know which
    ## HTTP server produced it.
    httpMethod*: string
    path*: string
    ## The adapter's observed transport scheme. It defaults to HTTP for
    ## socket-free tests and plain HTTP servers; a TLS adapter or a trusted
    ## reverse proxy may establish HTTPS through the security policy.
    scheme*: string
    ## Direct peer address supplied by the adapter. Security middleware uses
    ## this value to decide whether forwarded headers are trustworthy.
    remoteAddress*: string
    query*: Table[string, string]
    headers*: Table[string, string]
    cookies*: Table[string, string]
    body*: string
    pathParams*: Table[string, string]
    cancellation*: CancellationToken
    ## Optional request-scoped database connection. Application dispatch owns
    ## borrow/release; handlers only consume the adapter contract.
    database*: DatabaseAdapter
    ## Request-scoped services are created by Application.dispatch and disposed
    ## after the handler future completes. Adapters never own this lifetime.
    services*: ServiceContainer
    ## Authentication is adapter-neutral: security middleware binds a verified
    ## session subject here, while handlers never inspect cookie syntax.
    auth*: AuthContext
    ## The security middleware binds the verified/generated CSRF token here so
    ## server-rendered forms can echo the same token that will be stored in the
    ## response cookie. Keeping it request-scoped avoids generating two tokens
    ## during one GET/render cycle.
    csrfToken*: string
    ## Locale negotiation is a request value, not a template-engine concern.
    ## Localization middleware may populate it from Accept-Language before
    ## handlers render a response.
    locale*: string
    ## The offset is explicit request state rather than a process-global clock
    ## setting. IANA/DST resolution belongs to an application adapter.
    timezoneOffsetMinutes*: int
    ## Trace context is populated by observability middleware and propagated
    ## through adapters without coupling handlers to a tracing SDK.
    trace*: TraceContext

  AuthContext* = object
    ## An empty subject means anonymous. The boolean makes the contract
    ## explicit for handlers that should not infer identity from string state.
    authenticated*: bool
    subject*: string

  ResponseRepresentation* = enum
    ## Adapters use this hint to choose buffered HTTP, stream, SSE, or
    ## protocol-upgrade handling without changing the Handler contract.
    rrBuffered
    rrFile
    rrStream
    rrServerSentEvents
    rrWebSocket

  Response* = object
    ## A framework-neutral response that can be rendered by any adapter.
    status*: HttpCode
    headers*: Table[string, string]
    body*: string
    ## Retain the source path for adapter diagnostics and future zero-copy
    ## sendfile implementations; current adapters use the deterministic body.
    filePath*: string
    representation*: ResponseRepresentation
    ## Optional server-preferred alternatives. Adapters negotiate this list
    ## only at the wire boundary, so handlers can offer multiple protocols
    ## without coupling business logic to a concrete HTTP server.
    variants*: seq[Response]

  SseEvent* = object
    ## Structured SSE data keeps event metadata separate from wire framing.
    event*: string
    id*: string
    retryMs*: int
    data*: string

  WebSocketMessageKind* = enum
    ## The core contract is transport-neutral; adapters map these kinds to
    ## their library-specific frame/opcode representation.
    wsmText
    wsmBinary
    wsmPing
    wsmPong
    wsmClose

  WebSocketMessage* = object
    ## Close frames carry an optional protocol code while all other frames
    ## use payload as their application data.
    kind*: WebSocketMessageKind
    payload*: string
    closeCode*: int

  WebSocketSendProc* = proc (message: WebSocketMessage): Future[void] {.gcsafe.}
  WebSocketReceiveProc* = proc (): Future[WebSocketMessage] {.gcsafe.}
  WebSocketCloseProc* = proc (code: int, reason: string): Future[void] {.gcsafe.}

  WebSocketSession* = ref object
    ## Callback ownership belongs to the concrete adapter; core handlers only
    ## depend on this small send/receive/close boundary.
    sendMessage*: WebSocketSendProc
    receiveMessage*: WebSocketReceiveProc
    closeSession*: WebSocketCloseProc

  Handler* = proc (request: Request): Future[Response] {.gcsafe.}
  SyncHandler* = proc (request: Request): Response {.gcsafe.}
  WebSocketHandler* = proc (request: Request,
                            session: WebSocketSession): Future[void] {.gcsafe.}

  WebSocketRoute* = object
    ## WebSocket routes have a different completion model from HTTP routes:
    ## the handler owns a live session instead of returning one Response.
    pattern*: string
    name*: string
    handler*: WebSocketHandler
  Middleware* = proc (request: Request, next: Handler): Future[Response] {.gcsafe.}

  HandlerExecutionKind* = enum
    ## Route metadata makes synchronous work visible to checks and deployment
    ## policy instead of hiding it inside an async closure.
    hekAsync
    hekSync

  Route* = object
    ## A route is data, not a server-specific callback registration.
    ## This makes route inspection and future OpenAPI generation possible.
    httpMethod*: string
    pattern*: string
    name*: string
    handler*: Handler
    syncHandler*: SyncHandler
    middleware*: seq[Middleware]
    executionKind*: HandlerExecutionKind

  FrameworkError* = object of CatchableError
    ## Domain error used for predictable client-facing failures.
    status*: HttpCode
    code*: string

proc emptyTable(): Table[string, string] =
  ## Centralize table construction so every value object is initialized safely.
  initTable[string, string]()

proc newRequest*(httpMethod, path: string, body = ""): Request =
  ## Build a request suitable for tests and non-network adapters.
  result.httpMethod = httpMethod.toUpperAscii()
  result.path = path
  result.scheme = "http"
  result.remoteAddress = ""
  result.body = body
  result.query = emptyTable()
  result.headers = emptyTable()
  result.cookies = emptyTable()
  result.pathParams = emptyTable()
  result.auth = AuthContext(authenticated: false, subject: "")
  result.csrfToken = ""
  result.locale = ""
  result.trace = TraceContext()
  new(result.cancellation)
  result.cancellation.cancelled.store(false)

proc cancel*(token: CancellationToken) =
  ## Mark a request as cancelled without invalidating its request snapshot.
  if token != nil:
    token.cancelled.store(true)

proc isCancelled*(token: CancellationToken): bool =
  ## Nil is treated as an active token for manually constructed requests.
  token != nil and token.cancelled.load()

proc isCancelled*(request: Request): bool =
  ## Handler-facing convenience keeps cancellation checks readable.
  request.cancellation.isCancelled()

proc newResponse*(status: HttpCode, body = ""): Response =
  ## Create a response with an initialized header map.
  result.status = status
  result.body = body
  result.headers = emptyTable()
  result.representation = rrBuffered
  result.variants = @[]

proc responseVariants*(variants: openArray[Response]): Response =
  ## Preserve a server-ordered list of equivalent representations until an
  ## adapter sees the request's Accept header. Empty input is an explicit
  ## negotiation failure rather than an invalid partially initialized value.
  if variants.len == 0:
    result = newResponse(Http406, "Not Acceptable")
    result.headers["content-type"] = "text/plain; charset=utf-8"
    return
  result = variants[0]
  result.variants = @[]
  for variant in variants:
    var candidate = variant
    candidate.variants = @[]
    result.variants.add(candidate)

proc newWebSocketSession*(sendMessage: WebSocketSendProc = nil,
                          receiveMessage: WebSocketReceiveProc = nil,
                          closeSession: WebSocketCloseProc = nil): WebSocketSession =
  ## Construct an adapter-owned session without exposing socket internals.
  WebSocketSession(sendMessage: sendMessage, receiveMessage: receiveMessage,
    closeSession: closeSession)

proc textWebSocketMessage*(payload: string): WebSocketMessage =
  WebSocketMessage(kind: wsmText, payload: payload, closeCode: 0)

proc binaryWebSocketMessage*(payload: string): WebSocketMessage =
  WebSocketMessage(kind: wsmBinary, payload: payload, closeCode: 0)

proc controlWebSocketMessage*(kind: WebSocketMessageKind,
                              payload = ""): WebSocketMessage =
  ## Restrict control helper usage to protocol control kinds.
  if kind notin {wsmPing, wsmPong}:
    raise newException(ValueError, "Control WebSocket message must be ping or pong")
  WebSocketMessage(kind: kind, payload: payload, closeCode: 0)

proc isValidWebSocketCloseCode(code: int): bool =
  ## RFC 6455 reserves the gap between protocol-defined and application-defined
  ## close codes. Keeping this predicate in core means every adapter and test
  ## client applies the same close-frame contract.
  (code >= 1000 and code <= 1003) or
    (code >= 1007 and code <= 1014) or
    (code >= 3000 and code <= 4999)

proc closeWebSocketMessage*(code = 1000,
                            reason = ""): WebSocketMessage =
  if not isValidWebSocketCloseCode(code):
    raise newException(ValueError, "Invalid WebSocket close code: " & $code)
  ## The two-byte status code and UTF-8 reason share the 125-byte control
  ## frame limit; the reason therefore has at most 123 bytes. UTF-8 validity
  ## remains an adapter-owned byte decoder concern until a shared Unicode
  ## validation contract is introduced.
  if reason.len > 123:
    raise newException(ValueError, "WebSocket close reason exceeds 123 bytes")
  WebSocketMessage(kind: wsmClose, payload: reason, closeCode: code)

proc send*(session: WebSocketSession,
           message: WebSocketMessage): Future[void] =
  ## Fail explicitly when an adapter has not supplied a transport callback.
  if session.isNil or session.sendMessage.isNil:
    raise newException(ValueError, "WebSocket session cannot send without an adapter")
  session.sendMessage(message)

proc receive*(session: WebSocketSession): Future[WebSocketMessage] =
  if session.isNil or session.receiveMessage.isNil:
    raise newException(ValueError, "WebSocket session cannot receive without an adapter")
  session.receiveMessage()

proc close*(session: WebSocketSession, code = 1000,
            reason = ""): Future[void] =
  if session.isNil or session.closeSession.isNil:
    raise newException(ValueError, "WebSocket session cannot close without an adapter")
  session.closeSession(code, reason)

proc asyncHandler*(handler: SyncHandler): Handler =
  ## Adapt a synchronous, non-blocking handler to the async route contract.
  ## Application `getSync`/`postSync` routes use the execution module's
  ## executor boundary; this low-level adapter remains useful for explicitly
  ## non-blocking callbacks and compatibility code.
  result = proc(request: Request): Future[Response] {.async, gcsafe.} =
    return handler(request)

proc textResponse*(body: string, status = Http200): Response =
  ## Text responses default to an explicit content type.
  result = newResponse(status, body)
  result.headers["content-type"] = "text/plain; charset=utf-8"

proc htmlResponse*(body: string, status = Http200): Response =
  ## HTML responses are explicit so adapters do not infer content unsafely.
  result = newResponse(status, body)
  result.headers["content-type"] = "text/html; charset=utf-8"

proc jsonResponse*(body: string, status = Http200): Response =
  ## JSON responses use the same value object as HTML/text responses.
  result = newResponse(status, body)
  result.headers["content-type"] = "application/json; charset=utf-8"

proc jsonResponse*(document: JsonNode, status = Http200): Response =
  ## Convenience overload keeps JSON serialization at the response boundary.
  jsonResponse($document, status)

proc streamResponse*(body: string, contentType = "application/octet-stream",
                     status = Http200): Response =
  ## Represent a stream at the core boundary; concrete adapters may replace
  ## the buffered body with chunked writes while preserving this metadata.
  result = newResponse(status, body)
  result.representation = rrStream
  result.headers["content-type"] = contentType

proc fileResponse*(path: string, contentType = "application/octet-stream",
                   status = Http200): Response =
  ## Validate and snapshot an application-owned file at the response boundary.
  ## Keeping filesystem interpretation here prevents each adapter from
  ## inventing different path validation and error behavior.
  if path.strip().len == 0:
    raise newException(ValueError, "File response path cannot be empty")
  if not fileExists(path) or getFileInfo(path).kind != pcFile:
    raise newException(IOError, "File response path is not a file: " & path)
  result = newResponse(status, readFile(path))
  result.filePath = path
  result.representation = rrFile
  result.headers["content-type"] = contentType

proc validateSseSingleLineField(fieldName, value: string) =
  ## `data` is deliberately multiline, but event metadata is one logical SSE
  ## field per line. Rejecting CR/LF here prevents a caller from injecting a
  ## forged `id`, `event`, or `retry` field into the serialized stream.
  if value.contains('\r') or value.contains('\n'):
    raise newException(ValueError,
      "SSE " & fieldName & " field cannot contain a line break")

proc sseResponse*(events: openArray[SseEvent], status = Http200): Response =
  ## Serialize SSE fields according to the line-oriented event protocol.
  result = newResponse(status)
  result.representation = rrServerSentEvents
  result.headers["content-type"] = "text/event-stream; charset=utf-8"
  result.headers["cache-control"] = "no-cache"
  result.headers["connection"] = "keep-alive"
  for event in events:
    validateSseSingleLineField("event", event.event)
    validateSseSingleLineField("id", event.id)
    if event.event.len > 0:
      result.body.add("event: " & event.event & "\n")
    if event.id.len > 0:
      result.body.add("id: " & event.id & "\n")
    if event.retryMs >= 0:
      result.body.add("retry: " & $event.retryMs & "\n")
    let dataLines = event.data.splitLines()
    if dataLines.len == 0:
      result.body.add("data:\n")
    else:
      for line in dataLines:
        result.body.add("data: " & line & "\n")
    result.body.add("\n")

proc webSocketResponse*(body = ""): Response =
  ## Describe a WebSocket upgrade without coupling core code to a socket API.
  result = newResponse(Http101, body)
  result.representation = rrWebSocket
  result.headers["upgrade"] = "websocket"
  result.headers["connection"] = "Upgrade"
  result.headers["content-type"] = "application/websocket"

proc setCookie*(response: var Response, name, value: string,
                httpOnly = true, secure = false, sameSite = "Lax",
                maxAge = -1) =
  ## Add a safe default cookie header without coupling handlers to a server API.
  ## Cookie values are minimally sanitized here; a future cookie type can add
  ## full RFC parsing while preserving this simple framework contract.
  let safeValue = value.replace(";", "%3B").replace("\r", "").replace("\n", "")
  var headerValue = name & "=" & safeValue & "; Path=/; SameSite=" & sameSite
  if httpOnly:
    headerValue.add("; HttpOnly")
  if secure:
    headerValue.add("; Secure")
  if maxAge >= 0:
    headerValue.add("; Max-Age=" & $maxAge)
  response.headers["set-cookie"] = headerValue

proc redirectResponse*(location: string, status = Http302): Response =
  ## Redirect construction is kept in the core so every adapter handles it alike.
  result = newResponse(status)
  result.headers["location"] = location

proc ok*(response: Response): bool =
  ## A small convenience used by tests and future middleware diagnostics.
  response.status.int >= 200 and response.status.int < 400

proc header*(request: Request, name: string): Option[string] =
  ## Header lookup is case-insensitive, as required by HTTP.
  let wanted = name.toLowerAscii()
  for key, value in request.headers:
    if key.toLowerAscii() == wanted:
      return some(value)
  none(string)

proc header*(response: Response, name: string): Option[string] =
  ## Response header lookup mirrors request lookup for predictable tests.
  let wanted = name.toLowerAscii()
  for key, value in response.headers:
    if key.toLowerAscii() == wanted:
      return some(value)
  none(string)

## Contract tests for the first Mahanaim vertical slice.
##
## These tests exercise the framework without opening a network socket. That
## keeps failures deterministic while still covering the same dispatch pipeline
## a future Prologue/ASGI adapter will call.

import std/[asyncdispatch, httpcore, json, options, os, strutils, tables, times,
            unittest, uri]
import std/httpclient as hc
import pkg/cookiejar
import prologue/core/httpcore/httplogue
import prologue/core/request except Request
import prologue/mocking/mocking
import mahanaim

suite "Mahanaim core contracts":
  test "request and response value objects have safe defaults":
    let request = newRequest("get", "/health")
    check request.httpMethod == "GET"
    check request.path == "/health"
    check request.body == ""

    let response = textResponse("ok")
    check response.status == Http200
    check response.header("Content-Type").get() == "text/plain; charset=utf-8"

  test "router dispatches exact routes":
    let app = newApplication()
    proc health(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("ok")
    app.get("/health", "health", health)

    let response = waitFor app.dispatch(newRequest("GET", "/health"))
    check response.status == Http200
    check response.body == "ok"

  test "synchronous handler uses the common async dispatch contract":
    let app = newApplication()
    proc syncHealth(request: Request): mahanaim.Response {.gcsafe.} =
      discard request
      textResponse("sync ok")
    app.getSync("/sync-health", "sync-health", syncHealth)

    let response = waitFor app.dispatch(newRequest("GET", "/sync-health"))
    check response.status == Http200
    check response.body == "sync ok"
    let route = app.router.find(newRequest("GET", "/sync-health")).get()
    check route.executionKind == hekSync
    check route.syncHandler != nil
    check app.executor != nil
    check response.header("Content-Type").get() == "text/plain; charset=utf-8"
    let executionReport = checkExecution(app.router, app.executionPolicy)
    check executionReport.passed
    check executionReport.issues[0].code == "execution.sync.handler"

  test "thread pool executor keeps the async loop available while sync work runs":
    let executor = newThreadPoolExecutor(pollIntervalMs = 1)
    proc blockingJob(): mahanaim.Response {.gcsafe.} =
      sleep(30)
      textResponse("offloaded")
    proc observe(executor: ThreadPoolExecutor): Future[bool] {.async, gcsafe.} =
      let pending = executor.execute(blockingJob)
      await sleepAsync(1)
      discard await pending
      return true
    check waitFor observe(executor)

  test "thread pool executor propagates worker failures":
    let executor = newThreadPoolExecutor()
    proc failJob(): mahanaim.Response {.gcsafe.} =
      raise newException(ValueError, "worker failure")
    expect ValueError:
      discard waitFor executor.execute(failJob)

  test "request timeout returns 504 and marks cooperative cancellation":
    var config = defaultConfig()
    config.requestTimeoutMs = 5
    let app = newApplication(config)
    var observedCancellation = false
    proc slow(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      # The handler remains responsible for observing the token and stopping
      # its own work; the framework only controls the client-facing deadline.
      while not request.isCancelled():
        await sleepAsync(1)
      observedCancellation = request.isCancelled()
      return textResponse("late result")
    app.get("/slow", "slow", slow)

    proc dispatchAndDrain(app: Application): Future[mahanaim.Response] {.async.} =
      let response = await app.dispatch(newRequest("GET", "/slow"))
      # Let the cooperative handler observe cancellation before asserting it.
      await sleepAsync(10)
      return response

    let response = waitFor dispatchAndDrain(app)
    check response.status == Http504
    check response.body == "Request timed out"
    check observedCancellation

  test "negative request timeout is rejected by pre-flight checks":
    var config = defaultConfig()
    config.requestTimeoutMs = -1
    let report = checkConfig(config)
    check not report.passed
    check report.issues[0].code == "config.request-timeout.negative"

  test "execution policy can reject synchronous handlers before invocation":
    var policy = defaultExecutionPolicy()
    policy.allowSynchronousHandlers = false
    let app = newApplication(defaultConfig(), defaultSecurityPolicy(), policy)
    var invoked = false
    proc blocked(request: Request): mahanaim.Response {.gcsafe.} =
      invoked = true
      discard request
      textResponse("must not run")
    app.getSync("/blocked-sync", "blocked-sync", blocked)

    let response = waitFor app.dispatch(newRequest("GET", "/blocked-sync"))
    check response.status == Http500
    check response.body == "Synchronous handlers are disabled"
    check not invoked
    let report = checkApplication(app)
    check not report.passed
    check report.issues[0].code == "execution.sync.disabled"

  test "plugin can register a route through the application contract":
    let app = newApplication()
    proc pluginRoot(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("from plugin")
    proc registerPlugin(app: Application) =
      app.get("/plugin", "plugin-root", pluginRoot)
    app.use(registerPlugin)

    let response = waitFor app.dispatch(newRequest("GET", "/plugin"))
    check response.status == Http200
    check response.body == "from plugin"

  test "custom error handler receives route exceptions":
    let app = newApplication()
    proc failure(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      raise newException(ValueError, "secret failure detail")
    proc handleError(request: Request,
                     error: ref CatchableError): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("handled: " & error.msg, Http418)
    app.onError(handleError)
    app.get("/failure", "failure", failure)

    let response = waitFor app.dispatch(newRequest("GET", "/failure"))
    check response.status == Http418
    check response.body.startsWith("handled: secret failure detail")

  test "default error handler does not expose exception details":
    let app = newApplication()
    proc failure(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      raise newException(ValueError, "private detail")
    app.get("/default-failure", "default-failure", failure)

    let response = waitFor app.dispatch(newRequest("GET", "/default-failure"))
    check response.status == Http500
    check response.body == "Internal Server Error"

  test "security headers are applied to route and fallback responses":
    let app = newApplication()
    proc health(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("ok")
    app.get("/secure", "secure", health)

    let routeResponse = waitFor app.dispatch(newRequest("GET", "/secure"))
    let fallbackResponse = waitFor app.dispatch(newRequest("GET", "/missing-secure"))
    check routeResponse.header("X-Content-Type-Options").get() == "nosniff"
    check routeResponse.header("X-Frame-Options").get() == "DENY"
    check routeResponse.header("Content-Security-Policy").get() == "default-src 'self'"
    check fallbackResponse.header("X-Content-Type-Options").get() == "nosniff"

  test "security policy rejects hosts outside the allow list":
    var policy = defaultSecurityPolicy()
    policy.allowedHosts = @["example.com"]
    let app = newApplication(defaultConfig(), policy)
    proc health(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("should not run")
    app.get("/host", "host", health)
    var request = newRequest("GET", "/host")
    request.headers["host"] = "attacker.example"

    let response = waitFor app.dispatch(request)
    check response.status == Http400
    check response.body == "Invalid Host"
    check response.header("X-Frame-Options").get() == "DENY"

  test "security policy handles CORS and request size limits":
    var policy = defaultSecurityPolicy()
    policy.allowedOrigins = @["https://client.example"]
    policy.maxBodyBytes = 4
    let app = newApplication(defaultConfig(), policy)
    proc submit(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("accepted")
    app.post("/submit", "submit", submit)

    var allowed = newRequest("POST", "/submit", "1234")
    allowed.headers["origin"] = "https://client.example"
    let allowedResponse = waitFor app.dispatch(allowed)
    check allowedResponse.status == Http200
    check allowedResponse.header("Access-Control-Allow-Origin").get() ==
      "https://client.example"

    var preflight = newRequest("OPTIONS", "/submit")
    preflight.headers["origin"] = "https://client.example"
    let preflightResponse = waitFor app.dispatch(preflight)
    check preflightResponse.status == Http204
    check preflightResponse.header("Access-Control-Allow-Methods").isSome

    var denied = newRequest("POST", "/submit", "ok")
    denied.headers["origin"] = "https://attacker.example"
    let deniedResponse = waitFor app.dispatch(denied)
    check deniedResponse.status == Http403

    var oversized = newRequest("POST", "/submit", "12345")
    oversized.headers["origin"] = "https://client.example"
    let oversizedResponse = waitFor app.dispatch(oversized)
    check oversizedResponse.status == Http413

  test "security policy applies an application-wide fixed-window rate limit":
    var policy = defaultSecurityPolicy()
    policy.rateLimitRequests = 2
    policy.rateLimitWindowSeconds = 60
    let app = newApplication(defaultConfig(), policy)
    proc limited(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("accepted")
    app.get("/limited", "limited", limited)

    let first = waitFor app.dispatch(newRequest("GET", "/limited"))
    let second = waitFor app.dispatch(newRequest("GET", "/limited"))
    let third = waitFor app.dispatch(newRequest("GET", "/limited"))
    check first.status == Http200
    check first.header("X-RateLimit-Limit").get() == "2"
    check first.header("X-RateLimit-Remaining").get() == "1"
    check second.header("X-RateLimit-Remaining").get() == "0"
    check third.status == Http429
    check third.body == "Too Many Requests"
    check third.header("Retry-After").get() == "60"

    var invalidPolicy = defaultSecurityPolicy()
    invalidPolicy.rateLimitRequests = 1
    invalidPolicy.rateLimitWindowSeconds = 0
    let invalidReport = checkSecurityPolicy(invalidPolicy)
    check not invalidReport.passed
    check invalidReport.issues[0].code == "security.rate-limit.window-required"

  test "security policy issues and validates signed CSRF tokens":
    var policy = defaultSecurityPolicy()
    policy.csrfEnabled = true
    policy.csrfSecret = "test-only-secret-that-is-long-enough"
    let app = newApplication(defaultConfig(), policy)
    proc form(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("form")
    proc submit(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("submitted")
    app.get("/form", "csrf-form", form)
    app.post("/csrf-submit", "csrf-submit", submit)

    let formResponse = waitFor app.dispatch(newRequest("GET", "/form"))
    let cookieHeader = formResponse.header("Set-Cookie").get()
    let separator = cookieHeader.find('=')
    let endOfCookie = cookieHeader.find(';')
    let token = cookieHeader[separator + 1 ..< endOfCookie]
    check verifyCsrfToken(policy, token)

    let missingToken = waitFor app.dispatch(newRequest("POST", "/csrf-submit"))
    check missingToken.status == Http403

    var validRequest = newRequest("POST", "/csrf-submit")
    validRequest.cookies[policy.csrfCookieName] = token
    validRequest.headers[policy.csrfHeaderName] = token
    let validResponse = waitFor app.dispatch(validRequest)
    check validResponse.status == Http200
    check validResponse.body == "submitted"

    var forgedRequest = newRequest("POST", "/csrf-submit")
    let forgedToken = token[0 .. ^2] & (if token[^1] == '0': "1" else: "0")
    forgedRequest.cookies[policy.csrfCookieName] = forgedToken
    forgedRequest.headers[policy.csrfHeaderName] = forgedToken
    let forgedResponse = waitFor app.dispatch(forgedRequest)
    check forgedResponse.status == Http403

  test "signed cookie helpers enforce integrity and secure defaults":
    let secret = "cookie-signing-secret-that-is-long-enough"
    let signed = signValue(secret, "user.42")
    check verifySignedValue(secret, signed).get() == "user.42"
    check verifySignedValue(secret, signed[0 .. ^2] & "0").isNone
    check verifySignedValue("wrong-secret", signed).isNone
    check verifySignedValue("", signed).isNone

    var response = newResponse(Http200)
    response.setSignedCookie("session", "user.42", secret)
    let cookie = response.header("set-cookie").get()
    check cookie.contains("session=" & signed)
    check cookie.contains("HttpOnly")
    check cookie.contains("Secure")

    var request = newRequest("GET", "/account")
    request.cookies["session"] = signed
    check request.signedCookieValue("session", secret).get() == "user.42"
    expect ValueError:
      discard signValue("", "value")

  test "router extracts named path parameters":
    let app = newApplication()
    proc user(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse(request.pathParams["id"])
    app.get("/users/:id", "user-detail", user)

    let response = waitFor app.dispatch(newRequest("GET", "/users/42"))
    check response.status == Http200
    check response.body == "42"

  test "router supports typed parameters, wildcard paths, groups, and URL building":
    let app = newApplication()
    proc user(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse(request.pathParams["id"])
    proc asset(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse(request.pathParams["path"])
    proc addGroupHeader(request: Request,
                        next: Handler): Future[mahanaim.Response] {.async, gcsafe.} =
      var response = await next(request)
      response.headers["x-route-group"] = "api"
      return response
    proc groupHealth(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("group ok")

    app.get("/users/:id<int>", "typed-user", user)
    app.get("/assets/*path", "asset-file", asset)
    var groupMiddleware: seq[Middleware] = @[]
    groupMiddleware.add(proc(request: Request,
                             next: Handler): Future[mahanaim.Response] {.async, gcsafe.} =
      await addGroupHeader(request, next))
    let api = app.group("/api", groupMiddleware)
    app.get(api, "/health", "api-health", groupHealth)

    let typedResponse = waitFor app.dispatch(newRequest("GET", "/users/42"))
    check typedResponse.status == Http200
    check typedResponse.body == "42"
    let invalidTyped = waitFor app.dispatch(newRequest("GET", "/users/not-an-int"))
    check invalidTyped.status == Http404

    let wildcardResponse = waitFor app.dispatch(newRequest("GET", "/assets/css/site.css"))
    check wildcardResponse.status == Http200
    check wildcardResponse.body == "css/site.css"

    let groupedResponse = waitFor app.dispatch(newRequest("GET", "/api/health"))
    check groupedResponse.status == Http200
    check groupedResponse.header("X-Route-Group").get() == "api"

    var routeParams = initTable[string, string]()
    routeParams["id"] = "42"
    check app.router.urlFor("typed-user", routeParams) == "/users/42"
    check app.router.urlFor("api-health") == "/api/health"

  test "router dispatches the correct method when paths are shared":
    let app = newApplication()
    proc getResource(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("get")
    proc postResource(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("post")
    app.get("/resource", "get-resource", getResource)
    app.post("/resource", "post-resource", postResource)

    let getResponse = waitFor app.dispatch(newRequest("GET", "/resource"))
    let postResponse = waitFor app.dispatch(newRequest("POST", "/resource"))
    check getResponse.body == "get"
    check postResponse.body == "post"

  test "unknown route returns structured status":
    let app = newApplication()
    let response = waitFor app.dispatch(newRequest("GET", "/missing"))
    check response.status == Http404
    check not response.ok

  test "global middleware wraps route execution":
    let app = newApplication()
    proc addHeader(request: Request, next: Handler): Future[mahanaim.Response] {.async, gcsafe.} =
      var response = await next(request)
      response.headers["x-framework"] = "mahanaim"
      return response
    proc endpoint(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("ok")
    app.addMiddleware(addHeader)
    app.get("/", "root", endpoint)

    let response = waitFor app.dispatch(newRequest("GET", "/"))
    check response.header("X-Framework").get() == "mahanaim"

  test "lifecycle hooks are ordered and idempotent":
    let app = newApplication()
    var events: seq[string] = @[]
    app.onStartup(proc() = events.add("start"))
    app.onShutdown(proc() = events.add("stop"))
    app.startup()
    app.startup()
    app.shutdown()
    app.shutdown()
    check events == @["start", "stop"]

  test "environment configuration is parsed without logging secrets":
    putEnv("MAHANAIM_ENV", "test")
    putEnv("MAHANAIM_DEBUG", "false")
    putEnv("MAHANAIM_PORT", "9100")
    let config = loadConfig()
    check config.environment == "test"
    check config.debug == false
    check config.port == 9100
    delEnv("MAHANAIM_ENV")
    delEnv("MAHANAIM_DEBUG")
    delEnv("MAHANAIM_PORT")

  test "network adapter serves an application over HTTP":
    let app = newApplication()
    proc hello(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("hello over http")
    app.get("/hello", "hello", hello)
    let network = newNetworkServer(app, "127.0.0.1", 0)
    asyncCheck network.serve()

    # Binding happens inside the async server task. Poll briefly instead of
    # sleeping a fixed long interval, keeping the smoke test fast on CI.
    var attempts = 0
    while attempts < 50:
      try:
        if network.boundPort().uint16 > 0:
          break
      except OSError:
        discard
      waitFor sleepAsync(10)
      inc attempts
    check network.boundPort().uint16 > 0

    let client = hc.newAsyncHttpClient()
    let response = waitFor client.getContent("http://127.0.0.1:" & $network.boundPort().uint16 & "/hello")
    check response == "hello over http"
    client.close()
    network.close()

  test "Prologue adapter maps request context and response headers":
    var nativeHeaders = newHttpHeaders()
    nativeHeaders["Host"] = "example.test"
    var cookies = initCookieJar()
    cookies["session"] = "abc"
    var prologueRequestValue = request.initMockingRequest(
      HttpGet, nativeHeaders, parseUri("/search?q=nim"), cookies = cookies)

    let frameworkRequest = toFrameworkRequest(prologueRequestValue)
    check frameworkRequest.httpMethod == "GET"
    check frameworkRequest.path == "/search"
    check frameworkRequest.query["q"] == "nim"
    check frameworkRequest.header("host").get() == "example.test"
    check frameworkRequest.cookies["session"] == "abc"

    var frameworkResponse = jsonResponse("{\"ok\":true}")
    frameworkResponse.headers["x-adapter"] = "prologue"
    let prologueHeaders = toPrologueHeaders(frameworkResponse)
    check prologueHeaders["x-adapter", 0] == "prologue"

  test "Prologue server bridge delegates mocking requests and lifecycle":
    let app = newApplication()
    proc hello(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("hello from bridge")
    app.get("/bridge", "bridge-hello", hello)
    let adapter = newPrologueServer(app)
    adapter.server.mockApp()
    adapter.startup()
    adapter.startup()
    check app.started

    let nativeHeaders = newHttpHeaders()
    let nativeRequest = request.initMockingRequest(
      HttpGet, nativeHeaders, parseUri("/bridge"))
    let context = adapter.server.runOnce(nativeRequest)
    check context.response.code == Http200
    check context.response.body == "hello from bridge"

    adapter.shutdown()
    adapter.shutdown()
    check not app.started

  test "test client preserves request contract and cookie state":
    let app = newTestApplication()
    proc inspect(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      let query = request.query.getOrDefault("q")
      let clientHeader = request.header("x-client").get("missing")
      var response = textResponse(query & "|" & clientHeader)
      response.setCookie("session", "abc")
      return response
    proc submit(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse(request.cookies.getOrDefault("session") & ":" & request.body)
    app.get("/client", "client-inspect", inspect)
    app.post("/client-submit", "client-submit", submit)

    let client = newTestClient(app)
    let first = waitFor client.get("/client?q=nim", [("X-Client", "test")])
    check first.status == Http200
    check first.body == "nim|test"
    check client.hasLastResponse
    check client.lastResponse.body == first.body

    let second = waitFor client.post("/client-submit", "payload")
    check second.status == Http200
    check second.body == "abc:payload"

  test "test applications and clients are isolated by construction":
    let firstApp = newTestApplication()
    let secondApp = newTestApplication()
    let firstClient = newTestClient(firstApp)
    let secondClient = newTestClient(secondApp)
    check firstApp.router.routes.len == 0
    check secondApp.router.routes.len == 0
    check not firstClient.hasLastResponse
    check not secondClient.hasLastResponse

  test "project generator creates a safe starter project":
    let root = getTempDir() / "mahanaim_generated_test"
    if dirExists(root):
      removeDir(root)
    generateProject(ProjectSpec(name: "sample_app", root: root))
    check fileExists(root / "sample_app.nimble")
    check fileExists(root / "src" / "sample_app.nim")
    check fileExists(root / "tests" / "test_app.nim")
    expect IOError:
      generateProject(ProjectSpec(name: "sample_app", root: root))
    removeDir(root)

  test "explicit schema validates path query and header values":
    var request = newRequest("GET", "/users/42")
    request.pathParams["id"] = "42"
    request.query["page"] = "2"
    request.headers["x-api-key"] = "secret"
    let result = request.validate([
      integerField("id", flPath, minValue = 1),
      integerField("page", flQuery, defaultValue = "1", minValue = 1),
      stringField("x-api-key", flHeader, minLength = 6)
    ])
    check result.valid
    check result.integerValue("id").get() == 42
    check result.integerValue("page").get() == 2
    check result.stringValue("x-api-key").get() == "secret"

  test "validation returns all errors with source locations":
    var request = newRequest("GET", "/users/not-an-int")
    request.pathParams["id"] = "not-an-int"
    request.query["page"] = "0"
    let result = request.validate([
      integerField("id", flPath, minValue = 1),
      integerField("page", flQuery, minValue = 1),
      stringField("token", flHeader)
    ])
    check not result.valid
    check result.errors.len == 3
    check result.errors[0].location == "path"
    check result.errors[0].code == "invalid_integer"
    check result.errors[1].location == "query"
    check result.errors[2].code == "required"

  test "validation response uses problem json envelope":
    let issue = ValidationIssue(field: "page", location: "query",
      code: "invalid_integer", message: "Value must be an integer")
    let response = problemResponse(Http400, "Bad request", "Invalid input", [issue])
    let document = parseJson(response.body)
    check response.status == Http400
    check response.header("Content-Type").get() == "application/problem+json"
    check document["errors"][0]["field"].getStr() == "page"
    check document["errors"][0]["location"].getStr() == "query"

  test "named body fields are extracted from JSON":
    let request = newRequest("POST", "/users", "{\"name\":\"Ada\",\"age\":37}")
    let result = request.validate([
      stringField("name", flBody, minLength = 2),
      integerField("age", flBody, minValue = 18)
    ])
    check result.valid
    check result.stringValue("name").get() == "Ada"
    check result.integerValue("age").get() == 37

  test "form urlencoded body fields use the common validation contract":
    var request = newRequest("POST", "/profile", "name=Ada&age=37")
    request.headers["content-type"] = "application/x-www-form-urlencoded"
    let result = request.validate([
      stringField("name", flBody),
      integerField("age", flBody, minValue = 1)
    ])
    check result.valid
    check result.stringValue("name").get() == "Ada"
    check result.integerValue("age").get() == 37

  test "multipart body exposes fields and file metadata without adapter types":
    var request = newRequest("POST", "/upload",
      "--demo\r\n" &
      "Content-Disposition: form-data; name=\"title\"\r\n\r\n" &
      "avatar\r\n" &
      "--demo\r\n" &
      "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" &
      "Content-Type: text/plain\r\n\r\n" &
      "hello\r\n" &
      "--demo--\r\n")
    request.headers["content-type"] = "multipart/form-data; boundary=demo"
    let parsed = parseRequestBody(request)
    check parsed.valid
    check parsed.fields["title"] == "avatar"
    check parsed.parts.len == 2
    check parsed.parts[1].filename == "a.txt"
    check parsed.parts[1].contentType == "text/plain"
    check parsed.parts[1].content == "hello"
    let result = request.validate([stringField("title", flBody)])
    check result.valid

  test "malformed multipart body returns a body-scoped validation issue":
    var request = newRequest("POST", "/upload", "name=value")
    request.headers["content-type"] = "multipart/form-data"
    let result = request.validate([stringField("name", flBody)])
    check not result.valid
    check result.errors.len == 1
    check result.errors[0].location == "body"
    check result.errors[0].code == "missing_multipart_boundary"

  test "invalid JSON body reports a body-scoped issue":
    let request = newRequest("POST", "/users", "not-json")
    let result = request.validate([stringField("name", flBody)])
    check not result.valid
    check result.errors.len == 1
    check result.errors[0].location == "body"
    check result.errors[0].code == "invalid_json"

  test "problem response honors Accept content negotiation":
    var textRequest = newRequest("GET", "/invalid")
    textRequest.headers["accept"] = "text/plain"
    let textResponse = problemResponseFor(textRequest, Http400, "Bad request", "Invalid input")
    check textResponse.header("Content-Type").get() == "text/plain; charset=utf-8"
    check textResponse.body == "Bad request: Invalid input"

    var jsonRequest = newRequest("GET", "/invalid")
    jsonRequest.headers["accept"] = "application/problem+json"
    let jsonResponse = problemResponseFor(jsonRequest, Http400, "Bad request", "Invalid input")
    check jsonResponse.header("Content-Type").get() == "application/problem+json"
    check parseJson(jsonResponse.body)["title"].getStr() == "Bad request"

  test "response policy selects an accepted representation":
    var request = newRequest("GET", "/representation")
    request.headers["accept"] = "application/json"
    let selectedJson = negotiateResponse(request, [
      htmlResponse("<p>hello</p>"), jsonResponse("{\"message\":\"hello\"}")
    ])
    check selectedJson.header("Content-Type").get() == "application/json; charset=utf-8"

    request.headers["accept"] = "text/html"
    let selectedHtml = negotiateResponse(request, [
      htmlResponse("<p>hello</p>"), jsonResponse("{\"message\":\"hello\"}")
    ])
    check selectedHtml.header("Content-Type").get() == "text/html; charset=utf-8"

    request.headers["accept"] = "image/png"
    let unavailable = negotiateResponse(request, [htmlResponse("<p>hello</p>")])
    check unavailable.status == Http406

  test "response cookie helper applies safe defaults":
    var response = textResponse("ok")
    response.setCookie("session", "a;b", secure = true, maxAge = 3600)
    let cookie = response.header("Set-Cookie").get()
    check cookie.contains("session=a%3Bb")
    check cookie.contains("Path=/")
    check cookie.contains("HttpOnly")
    check cookie.contains("Secure")
    check cookie.contains("Max-Age=3600")

  test "configuration merges dotenv JSON TOML and environment values":
    let root = getTempDir() / "mahanaim_config_test"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    let dotenvPath = root / ".env"
    let jsonPath = root / "config.json"
    let tomlPath = root / "config.toml"
    writeFile(dotenvPath, "MAHANAIM_HOST=dotenv-host\nSECRET_TOKEN=dotenv-secret\n")
    writeFile(jsonPath, "{\"port\":9000,\"request_timeout_ms\":25,\"secrets\":{\"token\":\"json-secret\"}}")
    writeFile(tomlPath, "environment = \"staging\"\n[secrets]\ntoken = \"toml-secret\"\n")
    putEnv("MAHANAIM_PORT", "9100")
    putEnv("MAHANAIM_REQUEST_TIMEOUT_MS", "35")
    let config = loadConfig(dotenvPath, jsonPath, tomlPath)
    check config.host == "dotenv-host"
    check config.environment == "staging"
    check config.port == 9100
    check config.requestTimeoutMs == 35
    check config.secrets["token"] == "toml-secret"
    check redactSecrets("token=toml-secret", config) == "token=[REDACTED]"
    delEnv("MAHANAIM_PORT")
    delEnv("MAHANAIM_REQUEST_TIMEOUT_MS")
    removeDir(root)

  test "default config does not expose secrets":
    let config = defaultConfig()
    check config.secrets.len == 0
    check redactSecrets("nothing sensitive", config) == "nothing sensitive"

  test "model metadata is registry-backed and backend-neutral":
    var user = newModelMetadata("User", "users")
    user.addField(newModelField("id", modelInteger, primaryKey = true,
      indexed = true))
    user.addField(newModelField("email", modelString, unique = true,
      maxLength = 320))
    user.addIndex(ModelIndex(name: "users_email_idx", fields: @["email"],
      unique: true))
    user.addConstraint(ModelConstraint(name: "email_not_blank",
      expression: "email <> ''"))
    user.addRelation(ModelRelation(name: "posts", kind: relationOneToMany,
      targetModel: "Post", localField: "id", foreignField: "user_id"))

    var registry = initModelRegistry()
    registry.registerModel(user)
    check registry.model("User").isSome
    check registry.model("User").get().field("email").get().maxLength == 320
    check registry.modelNames() == @["User"]
    expect ValueError:
      user.addField(newModelField("id", modelInteger))
    expect ValueError:
      registry.registerModel(user)

    var broken = newModelMetadata("Broken", "broken")
    broken.addField(newModelField("id", modelInteger, primaryKey = true))
    broken.addIndex(ModelIndex(name: "missing_idx", fields: @["missing"]))
    var brokenRegistry = initModelRegistry()
    brokenRegistry.registerModel(broken)
    let brokenReport = checkModels(brokenRegistry)
    check not brokenReport.passed
    check brokenReport.issues[0].code == "model.index.unknown-field"

  test "metadata serializer renames fields and excludes sensitive values":
    var account = newModelMetadata("Account", "accounts")
    account.addField(newModelField("id", modelInteger, primaryKey = true))
    account.addField(newModelField("display_name", modelString,
      jsonName = "displayName"))
    account.addField(newModelField("email", modelString))
    account.addField(newModelField("bio", modelString, nullable = true))
    account.addField(newModelField("password_hash", modelString,
      sensitive = true, nullable = true))

    var values = initTable[string, JsonNode]()
    values["id"] = parseJson("7")
    values["display_name"] = parseJson("\"Ada\"")
    values["email"] = parseJson("\"ada@example.test\"")
    values["password_hash"] = parseJson("\"private\"")
    let serialized = serializeModel(account, values)
    check serialized.valid
    check serialized.document["displayName"].getStr() == "Ada"
    check serialized.document.hasKey("password_hash") == false
    check serialized.json().contains("displayName")

    var policy = defaultSerializationPolicy()
    policy.includeNulls = true
    var valuesWithoutSecret = values
    valuesWithoutSecret.del("password_hash")
    let withNulls = serializeModel(account, valuesWithoutSecret, policy)
    check withNulls.document["bio"].kind == JNull
    check withNulls.document.hasKey("password_hash") == false

    var invalidValues = values
    invalidValues["id"] = parseJson("\"seven\"")
    let invalid = serializeModel(account, invalidValues)
    check not invalid.valid
    check invalid.errors[0].code == "invalid_type"

    policy.rejectUnknownFields = true
    invalidValues["unknown"] = parseJson("true")
    let unknown = serializeModel(account, invalidValues, policy)
    check not unknown.valid
    check unknown.errors[^1].code == "unknown_field"

  test "framework checks aggregate config route and security failures":
    let validReport = checkApplication(newApplication())
    check validReport.passed
    check validReport.issues.len == 0

    var invalidPolicy = defaultSecurityPolicy()
    invalidPolicy.csrfEnabled = true
    invalidPolicy.csrfSecret = "too-short"
    let app = newApplication(defaultConfig(), invalidPolicy)
    app.config.port = 0
    proc route(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("route")
    app.get("/checked", "checked-a", route)
    app.get("/checked", "checked-b", route)

    let report = checkApplication(app, invalidPolicy)
    check not report.passed
    check report.issues.len == 3
    check report.issues[0].code == "config.port.invalid"
    check report.issues[1].code == "route.declaration.duplicate"
    check report.issues[2].code == "security.csrf-secret.weak"

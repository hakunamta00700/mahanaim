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

type
  TestApplication* = Application

  TestClient* = ref object
    ## Cookie state belongs to one client, allowing isolated browser-like tests.
    app*: Application
    cookies*: Table[string, string]
    hasLastResponse*: bool
    lastResponse*: Response

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

proc applyCookieHeader(request: var Request, headerValue: string) =
  ## Parse both client-managed and explicitly supplied cookie headers.
  for pair in headerValue.split(';'):
    let pieces = pair.split('=', maxsplit = 1)
    if pieces.len == 2:
      request.cookies[pieces[0].strip()] = pieces[1].strip()

proc requestInternal(client: TestClient, httpMethod, path, body: string,
                      headers: seq[(string, string)]): Future[Response] {.async.} =
  ## Build the same framework Request shape as a real HTTP adapter.
  let parsed = parseUri(path)
  let requestPath = if parsed.path.len > 0: parsed.path else: "/"
  var frameworkRequest = newRequest(httpMethod, requestPath, body)
  for key, value in decodeQuery(parsed.query):
    frameworkRequest.query[key] = value
  for header in headers:
    frameworkRequest.headers[header[0].toLowerAscii()] = header[1]
  let cookies = client.cookieHeader()
  let suppliedCookie = frameworkRequest.header("cookie")
  if suppliedCookie.isSome:
    frameworkRequest.applyCookieHeader(suppliedCookie.get())
  elif cookies.len > 0:
    frameworkRequest.headers["cookie"] = cookies
    frameworkRequest.applyCookieHeader(cookies)
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

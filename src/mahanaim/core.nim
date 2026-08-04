## Core contracts for the Mahanaim request pipeline.
##
## This module intentionally contains no server or database implementation.
## Keeping the value objects and handler contracts small lets adapters (such as
## Prologue) evolve without leaking their types into application code.

import std/[asyncdispatch, httpcore, json, options, strutils, tables]

type
  Request* = object
    ## A framework-neutral HTTP request snapshot.
    ##
    ## The adapter layer is responsible for parsing the wire request and
    ## populating this object. Application handlers never need to know which
    ## HTTP server produced it.
    httpMethod*: string
    path*: string
    query*: Table[string, string]
    headers*: Table[string, string]
    cookies*: Table[string, string]
    body*: string
    pathParams*: Table[string, string]

  Response* = object
    ## A framework-neutral response that can be rendered by any adapter.
    status*: HttpCode
    headers*: Table[string, string]
    body*: string

  Handler* = proc (request: Request): Future[Response] {.gcsafe.}
  SyncHandler* = proc (request: Request): Response {.gcsafe.}
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
  result.body = body
  result.query = emptyTable()
  result.headers = emptyTable()
  result.cookies = emptyTable()
  result.pathParams = emptyTable()

proc newResponse*(status: HttpCode, body = ""): Response =
  ## Create a response with an initialized header map.
  result.status = status
  result.body = body
  result.headers = emptyTable()

proc asyncHandler*(handler: SyncHandler): Handler =
  ## Adapt a synchronous, non-blocking handler to the async route contract.
  ##
  ## This wrapper preserves one handler model for application code. It must not
  ## be used for file/network/database blocking work; such work belongs in a
  ## future executor adapter so the event loop remains responsive.
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

## Core contracts for the Mahanaim request pipeline.
##
## This module intentionally contains no server or database implementation.
## Keeping the value objects and handler contracts small lets adapters (such as
## Prologue) evolve without leaking their types into application code.

import std/[asyncdispatch, httpcore, options, strutils, tables]

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
  Middleware* = proc (request: Request, next: Handler): Future[Response] {.gcsafe.}

  Route* = object
    ## A route is data, not a server-specific callback registration.
    ## This makes route inspection and future OpenAPI generation possible.
    httpMethod*: string
    pattern*: string
    name*: string
    handler*: Handler
    middleware*: seq[Middleware]

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

proc textResponse*(body: string, status = Http200): Response =
  ## Text responses default to an explicit content type.
  result = newResponse(status, body)
  result.headers["content-type"] = "text/plain; charset=utf-8"

proc htmlResponse*(body: string, status = Http200): Response =
  ## HTML responses are explicit so adapters do not infer content unsafely.
  result = newResponse(status, body)
  result.headers["content-type"] = "text/html; charset=utf-8"

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

## Prologue request/response adapter.
##
## Prologue types stop at this boundary.  The application, router, validation,
## and security modules continue to depend only on Mahanaim's core contracts,
## so a future server adapter can be added without changing user handlers.

import std/[asyncdispatch, httpcore, strutils, tables, uri]
import pkg/cookiejar
import prologue/core/httpcore/httplogue
import prologue/core/request as prologueRequest
import ./body_parser
import ./core
import ./upload_storage

proc copyPrologueHeaders(headers: HttpHeaders): Table[string, string] =
  ## Normalize headers once, matching the standard-library adapter behavior.
  result = initTable[string, string]()
  for key, value in headers:
    result[key.toLowerAscii()] = value

proc toFrameworkRequest*(request: prologueRequest.Request): core.Request =
  ## Convert method, path, query, headers, cookies, and body without exposing
  ## Prologue's Context or NativeRequest to the rest of the framework.
  result = newRequest($request.reqMethod, request.path(), request.body())
  ## Preserve the adapter-observed scheme. The peer address remains empty for
  ## this transport-neutral bridge unless a concrete Prologue backend exposes
  ## it; that deliberately prevents forwarded headers from being trusted.
  result.scheme = request.scheme()
  result.query = initTable[string, string]()
  for key, value in decodeQuery(request.query()):
    result.query[key] = value
  result.headers = copyPrologueHeaders(request.headers())
  result.cookies = initTable[string, string]()
  for name, value in request.cookies.pairs:
    result.cookies[name] = value

proc parsePrologueBody*(request: prologueRequest.Request): BodyParseResult =
  ## Keep Prologue multipart/form data on the same parser contract as every
  ## other adapter; callers never need to inspect NativeRequest internals.
  parseRequestBody(toFrameworkRequest(request))

proc savePrologueUpload*(request: prologueRequest.Request, fieldName: string,
                         policy: UploadPolicy): StoredUpload =
  ## Locate one file part and delegate validation/storage to the shared policy.
  let parsed = parsePrologueBody(request)
  if not parsed.valid:
    raise newException(UploadValidationError, parsed.errorMessage)
  for part in parsed.parts:
    if part.name == fieldName and part.filename.len > 0:
      return saveUpload(part, policy)
  raise newException(UploadValidationError,
    "Multipart upload field not found: " & fieldName)

proc toPrologueHeaders*(response: core.Response): ResponseHeaders =
  ## Translate response headers while preserving repeated-header semantics at
  ## the Prologue boundary (notably Set-Cookie and Vary).
  result = initResponseHeaders()
  for key, value in response.headers:
    result.add(key, value)

proc respond*(request: prologueRequest.Request,
              response: core.Response): Future[void] {.async.} =
  ## A single response bridge keeps adapters from duplicating header policy.
  await request.respond(response.status, response.body,
    toPrologueHeaders(response))

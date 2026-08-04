## Secure-by-default HTTP middleware.
##
## This security layer covers response headers, host validation, CORS, and
## request size limits. CSRF, authentication, and rate limiting remain separate
## policies so each concern can be tested and replaced independently.

import std/[asyncdispatch, httpcore, options, strutils, tables]
import ./core

type
  SecurityPolicy* = object
    ## Explicit policy values make deployment review possible.
    allowedHosts*: seq[string]
    allowedOrigins*: seq[string]
    corsMethods*: string
    corsHeaders*: string
    maxBodyBytes*: int
    contentSecurityPolicy*: string
    frameOptions*: string
    referrerPolicy*: string

proc defaultSecurityPolicy*(): SecurityPolicy =
  ## Conservative headers that are safe for server-rendered applications.
  SecurityPolicy(
    allowedHosts: @[],
    allowedOrigins: @[],
    corsMethods: "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    corsHeaders: "Content-Type, Authorization",
    maxBodyBytes: 1024 * 1024,
    contentSecurityPolicy: "default-src 'self'",
    frameOptions: "DENY",
    referrerPolicy: "strict-origin-when-cross-origin")

proc hostWithoutPort(host: string): string =
  ## Host headers commonly include a development port.
  let separator = host.rfind(':')
  if separator > 0 and host[separator + 1 .. ^1].allCharsInSet({'0'..'9'}):
    return host[0 ..< separator]
  host

proc allowedHost(policy: SecurityPolicy, host: string): bool =
  if policy.allowedHosts.len == 0:
    return true
  let normalized = hostWithoutPort(host).toLowerAscii()
  for allowed in policy.allowedHosts:
    if normalized == hostWithoutPort(allowed).toLowerAscii():
      return true
  false

proc addSecurityHeaders(response: var Response, policy: SecurityPolicy) =
  ## Do not overwrite application-specific values; policy supplies defaults.
  if response.header("x-content-type-options").isNone:
    response.headers["x-content-type-options"] = "nosniff"
  if response.header("x-frame-options").isNone:
    response.headers["x-frame-options"] = policy.frameOptions
  if response.header("content-security-policy").isNone:
    response.headers["content-security-policy"] = policy.contentSecurityPolicy
  if response.header("referrer-policy").isNone:
    response.headers["referrer-policy"] = policy.referrerPolicy

proc allowedOrigin(policy: SecurityPolicy, origin: string): bool =
  ## Never emit a wildcard CORS response from the secure default policy.
  for allowed in policy.allowedOrigins:
    if origin == allowed:
      return true
  false

proc addCorsHeaders(response: var Response, policy: SecurityPolicy, origin: string) =
  ## CORS headers are emitted only after an exact origin match.
  response.headers["access-control-allow-origin"] = origin
  response.headers["access-control-allow-methods"] = policy.corsMethods
  response.headers["access-control-allow-headers"] = policy.corsHeaders
  response.headers["vary"] = "Origin"

proc securityMiddleware*(policy: SecurityPolicy): Middleware =
  ## Validate Host before invoking application code and decorate every result.
  result = proc(request: Request, next: Handler): Future[Response] {.async, gcsafe.} =
    let host = request.header("host")
    if policy.allowedHosts.len > 0 and
       (host.isNone or not allowedHost(policy, host.get())):
      var rejected = textResponse("Invalid Host", Http400)
      addSecurityHeaders(rejected, policy)
      return rejected
    let origin = request.header("origin")
    if origin.isSome and policy.allowedOrigins.len > 0 and
       not allowedOrigin(policy, origin.get()):
      var rejected = textResponse("Origin Not Allowed", Http403)
      addSecurityHeaders(rejected, policy)
      return rejected
    if policy.maxBodyBytes > 0 and request.body.len > policy.maxBodyBytes:
      var rejected = textResponse("Request Entity Too Large", Http413)
      addSecurityHeaders(rejected, policy)
      return rejected
    if request.httpMethod == "OPTIONS" and origin.isSome:
      var preflight = newResponse(Http204)
      addCorsHeaders(preflight, policy, origin.get())
      addSecurityHeaders(preflight, policy)
      return preflight
    var response = await next(request)
    if origin.isSome and policy.allowedOrigins.len > 0:
      addCorsHeaders(response, policy, origin.get())
    addSecurityHeaders(response, policy)
    return response

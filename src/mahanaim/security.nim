## Secure-by-default HTTP middleware.
##
## This security layer covers response headers, host validation, CORS, request
## size limits, and an explicit signed double-submit CSRF policy. Authentication
## and rate limiting remain separate policies so each concern can be tested and
## replaced independently.

import std/[asyncdispatch, httpcore, options, strutils, sysrand, tables]
import nimcrypto
import ./core

type
  SecurityPolicy* = object
    ## Explicit policy values make deployment review possible.
    allowedHosts*: seq[string]
    allowedOrigins*: seq[string]
    corsMethods*: string
    corsHeaders*: string
    maxBodyBytes*: int
    csrfEnabled*: bool
    csrfSecret*: string
    csrfCookieName*: string
    csrfHeaderName*: string
    csrfCookieSecure*: bool
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
    csrfEnabled: false,
    csrfSecret: "",
    csrfCookieName: "mahanaim_csrf",
    csrfHeaderName: "x-csrf-token",
    csrfCookieSecure: false,
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

const hexDigits = "0123456789abcdef"

proc hexEncode(bytes: openArray[byte]): string =
  ## Keep token serialization URL/cookie-safe without a second encoding layer.
  result = newStringOfCap(bytes.len * 2)
  for value in bytes:
    result.add(hexDigits[int(value shr 4)])
    result.add(hexDigits[int(value and 0x0F)])

proc constantTimeEquals(left, right: string): bool =
  ## Compare every byte so an attacker cannot learn the signature prefix from
  ## timing differences. Length is folded into the accumulator as well.
  var difference = left.len xor right.len
  let commonLength = min(left.len, right.len)
  for index in 0 ..< commonLength:
    difference = difference or (ord(left[index]) xor ord(right[index]))
  difference == 0

proc signValue*(secret, value: string): string =
  ## Sign a cookie-safe value without exposing the signing key to adapters.
  ## Values may contain dots; verification uses the final separator so the
  ## original value remains intact.
  if secret.len == 0:
    raise newException(ValueError, "Signing secret must be configured")
  value & "." & ($sha256.hmac(secret, value)).toLowerAscii()

proc verifySignedValue*(secret, signedValue: string): Option[string] =
  ## Return the payload only when the complete signature matches in constant
  ## time. Invalid input is represented as `none`, not an exception.
  if secret.len == 0:
    return none(string)
  let separator = signedValue.rfind('.')
  if separator < 0 or separator == signedValue.high:
    return none(string)
  let value = signedValue[0 ..< separator]
  let signature = signedValue[separator + 1 .. ^1]
  let expected = ($sha256.hmac(secret, value)).toLowerAscii()
  if constantTimeEquals(signature, expected): some(value)
  else: none(string)

proc setSignedCookie*(response: var Response, name, value, secret: string,
                      httpOnly = true, secure = true, sameSite = "Lax",
                      maxAge = -1) =
  ## Signed cookies default to HttpOnly and Secure because they commonly carry
  ## identity or authorization state. Callers must provide an explicit secret.
  response.setCookie(name, signValue(secret, value), httpOnly, secure,
    sameSite, maxAge)

proc signedCookieValue*(request: Request, name, secret: string): Option[string] =
  ## Read and verify one signed cookie without coupling handlers to a server
  ## cookie-jar implementation.
  if not request.cookies.hasKey(name):
    return none(string)
  verifySignedValue(secret, request.cookies[name])

proc csrfToken*(policy: SecurityPolicy): string =
  ## Create a signed token for server-rendered forms or API clients.
  if policy.csrfSecret.len == 0:
    raise newException(ValueError, "CSRF secret must be configured")
  let nonce = hexEncode(sysrand.urandom(32))
  signValue(policy.csrfSecret, nonce)

proc verifyCsrfToken*(policy: SecurityPolicy, token: string): bool =
  ## Validate structure and signature independently of where the token came
  ## from; the middleware later enforces the cookie/header equality rule.
  verifySignedValue(policy.csrfSecret, token).isSome

proc csrfProtectedMethod(httpMethod: string): bool =
  ## Safe methods may obtain a token; state-changing methods must prove it.
  httpMethod.toUpperAscii() notin ["GET", "HEAD", "OPTIONS", "TRACE"]

proc addCsrfCookie(response: var Response, policy: SecurityPolicy,
                   token: string) =
  ## HttpOnly is intentionally false: browser code must echo this token in the
  ## request header, while SameSite=Lax and Secure remain safe defaults.
  response.setCookie(policy.csrfCookieName, token, httpOnly = false,
    secure = policy.csrfCookieSecure, sameSite = "Lax")

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
    if policy.csrfEnabled:
      if policy.csrfSecret.len == 0:
        var rejected = textResponse("CSRF Policy Misconfigured", Http500)
        addSecurityHeaders(rejected, policy)
        return rejected
      if csrfProtectedMethod(request.httpMethod):
        let cookieToken = request.cookies.getOrDefault(policy.csrfCookieName)
        let headerToken = request.header(policy.csrfHeaderName)
        if cookieToken.len == 0 or headerToken.isNone or
           not verifyCsrfToken(policy, cookieToken) or
           not constantTimeEquals(cookieToken, headerToken.get()):
          var rejected = textResponse("CSRF Validation Failed", Http403)
          addSecurityHeaders(rejected, policy)
          return rejected
    if request.httpMethod == "OPTIONS" and origin.isSome:
      var preflight = newResponse(Http204)
      addCorsHeaders(preflight, policy, origin.get())
      addSecurityHeaders(preflight, policy)
      return preflight
    var response = await next(request)
    if policy.csrfEnabled and
       request.cookies.getOrDefault(policy.csrfCookieName).len == 0:
      addCsrfCookie(response, policy, csrfToken(policy))
    if origin.isSome and policy.allowedOrigins.len > 0:
      addCorsHeaders(response, policy, origin.get())
    addSecurityHeaders(response, policy)
    return response

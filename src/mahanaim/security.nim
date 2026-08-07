## Secure-by-default HTTP middleware.
##
## This security layer covers response headers, host validation, CORS, request
## size limits, and an explicit signed double-submit CSRF policy. Authentication
## and rate limiting remain separate policies so each concern can be tested and
## replaced independently.

import std/[asyncdispatch, base64, httpcore, json, locks, monotimes, options, strutils, sysrand, tables, times]
import nimcrypto
import ./body_parser
import ./core

const
  ## The default limiter is intentionally bounded but generous enough for a
  ## small application. Hosts with per-user or distributed quotas can replace
  ## both values and inject a shared RateLimitStore.
  defaultRateLimitRequests* = 1_000
  defaultRateLimitWindowSeconds* = 60

type
  RateLimitDecision* = object
    ## A store returns only policy data; middleware owns HTTP status/header
    ## rendering and therefore remains independent from storage technology.
    allowed*: bool
    remaining*: int
    retryAfter*: int

  RateLimitCounterResult* = object
    ## A Redis/Valkey client returns the result of one atomic server-side
    ## increment. The framework never assumes a local clock or local count.
    count*: int
    ttlSeconds*: int

  RateLimitCounterClient* = ref object of RootObj
    ## Transport implementations can use any Redis/Valkey client library.
    ## The core depends only on this small atomic counter contract.

  RateLimitStore* = ref object of RootObj
    ## Implementations may use an atomic remote increment, a database row, or
    ## another shared counter without changing SecurityPolicy semantics.

  RedisValkeyRateLimitStore* = ref object of RateLimitStore
    client*: RateLimitCounterClient
    maxRetries*: int

  InMemoryRateLimitStore* = ref object of RateLimitStore
    windows: Table[string, tuple[started: MonoTime, count: int]]
    ## A local adapter must remain bounded even when callers send unbounded
    ## distinct keys. Distributed stores enforce an equivalent policy through
    ## their configured maxmemory/eviction settings.
    maxKeys: int
    lock: Lock

type
  SessionPolicy* = object
    ## Bind a verified signed session cookie to the framework request. This is
    ## intentionally a small authentication seam; a database/session store
    ## can replace cookie issuance without changing handler contracts.
    enabled*: bool
    cookieName*: string
    secret*: string
    legacySecrets*: seq[string]
    secureCookie*: bool
    requireAuthentication*: bool

  AuthBackend* = ref object of RootObj
    ## Authentication is a replaceable verification boundary. Middleware only
    ## consumes the resulting AuthContext and never parses a credential format.

  SessionCookieAuthBackend* = ref object of AuthBackend
    policy*: SessionPolicy

  BearerTokenAuthBackend* = ref object of AuthBackend
    ## This signed bearer token is intentionally opaque to the core. A JWT or
    ## external introspection adapter can implement the same AuthBackend API.
    secret*: string
    headerName*: string
    scheme*: string

  JwtKey* = object
    ## The key id is carried in the JWT header, making retirement explicit.
    id*: string
    secret*: string

  JwtClaims* = object
    subject*: string
    issuer*: string
    audience*: string
    issuedAt*: int64
    notBefore*: int64
    expiresAt*: int64
    tokenId*: string
    keyId*: string

  JwtRevocationStore* = ref object of RootObj
    ## Token ids are revocable until their expiry. Backends must fail closed
    ## when this check cannot be completed.

  InMemoryJwtRevocationStore* = ref object of JwtRevocationStore
    revoked: Table[string, int64]
    lock: Lock

  JwtTokenAuthBackend* = ref object of AuthBackend
    ## A compact HS256 JWT adapter with explicit issuer/audience/key policy.
    keys*: seq[JwtKey]
    issuer*: string
    audience*: string
    headerName*: string
    scheme*: string
    clockSkewSeconds*: int64
    revocations*: JwtRevocationStore

  SignedValueVerification* = object
    ## Keyring verification reports whether a value was signed by a legacy key
    ## so callers can rotate the cookie on the next successful response.
    value*: string
    keyIndex*: int
    needsRotation*: bool

  SecurityPolicy* = object
    ## Explicit policy values make deployment review possible.
    ## `requireHttps` is opt-in because the framework's standard development
    ## server is plain HTTP. Production applications should enable it when
    ## the TLS terminator has been configured and tested.
    requireHttps*: bool
    ## Forwarded headers are accepted only when the adapter reports a direct
    ## peer in this exact allow-list. An integer hop count alone is not enough
    ## to establish trust because an untrusted client can forge that shape.
    trustedProxies*: seq[string]
    allowedHosts*: seq[string]
    allowedOrigins*: seq[string]
    corsMethods*: string
    corsHeaders*: string
    maxBodyBytes*: int
    ## A zero value disables the process-local application-wide limiter.
    rateLimitRequests*: int
    rateLimitWindowSeconds*: int
    ## A shared store replaces process-local state when multiple application
    ## instances must enforce one quota. The store contract is deliberately
    ## backend-neutral so Redis/Valkey adapters do not leak into middleware.
    rateLimitStore*: RateLimitStore
    rateLimitKey*: string
    csrfEnabled*: bool
    csrfSecret*: string
    csrfCookieName*: string
    csrfHeaderName*: string
    csrfCookieSecure*: bool
    session*: SessionPolicy
    ## Multiple credential transports can be composed for one application.
    ## The legacy singular authBackend remains supported for source
    ## compatibility, while this list lets browser sessions and API bearer
    ## tokens reach the same AuthContext/route-guard boundary.
    authBackends*: seq[AuthBackend]
    authBackend*: AuthBackend
    contentSecurityPolicy*: string
    frameOptions*: string
    referrerPolicy*: string

proc defaultSecurityPolicy*(): SecurityPolicy =
  ## Conservative headers that are safe for server-rendered applications.
  SecurityPolicy(
    requireHttps: false,
    trustedProxies: @[],
    allowedHosts: @[],
    allowedOrigins: @[],
    corsMethods: "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    corsHeaders: "Content-Type, Authorization",
    maxBodyBytes: 1024 * 1024,
    rateLimitRequests: defaultRateLimitRequests,
    rateLimitWindowSeconds: defaultRateLimitWindowSeconds,
    rateLimitStore: nil,
    rateLimitKey: "mahanaim:application",
    csrfEnabled: false,
    csrfSecret: "",
    csrfCookieName: "mahanaim_csrf",
    csrfHeaderName: "x-csrf-token",
    csrfCookieSecure: false,
    session: SessionPolicy(enabled: false, cookieName: "mahanaim_session",
      secret: "", legacySecrets: @[], secureCookie: true,
      requireAuthentication: false),
    authBackends: @[],
    authBackend: nil,
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

proc isTrustedProxy(policy: SecurityPolicy, request: Request): bool =
  ## Keep proxy trust explicit and adapter-owned. If no peer address is known,
  ## forwarded headers remain untrusted instead of silently becoming a bypass.
  let peer = request.remoteAddress.strip()
  if peer.len == 0:
    return false
  for trusted in policy.trustedProxies:
    if peer == trusted.strip():
      return true
  false

proc firstForwardedValue(request: Request, headerName: string): Option[string] =
  ## RFC-style forwarded headers may contain a comma-separated chain. The
  ## first value is the client-facing value, and is used only after the direct
  ## peer has passed `isTrustedProxy`.
  let header = request.header(headerName)
  if header.isNone:
    return none(string)
  let value = header.get().split(',')[0].strip()
  if value.len == 0:
    return none(string)
  some(value)

proc effectiveScheme(policy: SecurityPolicy, request: Request): string =
  ## A framework-neutral request carries the adapter-observed scheme. A
  ## trusted TLS terminator can override it with X-Forwarded-Proto.
  result = request.scheme.strip().toLowerAscii()
  if result.len == 0:
    result = "http"
  if policy.isTrustedProxy(request):
    let forwarded = request.firstForwardedValue("x-forwarded-proto")
    if forwarded.isSome:
      result = forwarded.get().toLowerAscii()

proc effectiveHost(policy: SecurityPolicy, request: Request): Option[string] =
  ## Host validation uses the public host only after the direct peer is trusted.
  if policy.isTrustedProxy(request):
    let forwarded = request.firstForwardedValue("x-forwarded-host")
    if forwarded.isSome:
      return forwarded
  request.header("host")

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

type
  RateLimitState = ref object
    ## State is owned by one middleware instance, so tests and applications do
    ## not accidentally share counters through a process-global variable.
    windowStarted: MonoTime
    requestCount: int

proc newRateLimitState(): RateLimitState =
  ## Initialize the first window when the application is constructed.
  new(result)
  result.windowStarted = getMonoTime()

method consume*(store: RateLimitStore, key: string, limit,
                windowSeconds: int): RateLimitDecision {.base, gcsafe.} =
  ## A base store fails explicitly instead of silently allowing requests.
  discard store
  discard key
  discard limit
  discard windowSeconds
  raise newException(ValueError, "RateLimitStore.consume is not implemented")

method incrementFixedWindow*(client: RateLimitCounterClient, key: string,
                             windowSeconds: int): RateLimitCounterResult {.base, gcsafe.} =
  ## A concrete client should execute an atomic INCR/EXPIRE operation or an
  ## equivalent Lua script and return the server-side count and TTL.
  discard client
  discard key
  discard windowSeconds
  raise newException(ValueError,
    "RateLimitCounterClient.incrementFixedWindow is not implemented")

proc newRedisValkeyRateLimitStore*(client: RateLimitCounterClient,
                                   maxRetries = 1): RedisValkeyRateLimitStore =
  ## Keep retry bounded and immediate so middleware never sleeps the event loop.
  if client == nil:
    raise newException(ValueError, "rate limit counter client is required")
  if maxRetries < 0:
    raise newException(ValueError, "rate limit maxRetries must not be negative")
  new(result)
  result.client = client
  result.maxRetries = maxRetries

method consume*(store: RedisValkeyRateLimitStore, key: string, limit,
                windowSeconds: int): RateLimitDecision {.gcsafe.} =
  ## Retry only the atomic command. If every attempt fails, propagate the
  ## backend error so security middleware returns a fail-closed 503 response.
  var lastError: ref CatchableError
  for attempt in 0 .. store.maxRetries:
    try:
      let counter = store.client.incrementFixedWindow(key, windowSeconds)
      if counter.count < 1 or counter.ttlSeconds < 0:
        raise newException(ValueError, "invalid remote rate limit counter result")
      result.allowed = counter.count <= limit
      result.remaining = if result.allowed:
        max(0, limit - counter.count) else: 0
      result.retryAfter = if result.allowed:
        0 else: max(1, counter.ttlSeconds)
      return
    except CatchableError as error:
      lastError = error
      if attempt == store.maxRetries:
        raise error
  if lastError != nil:
    raise lastError

proc newInMemoryRateLimitStore*(maxKeys = 10_000): InMemoryRateLimitStore =
  ## This backend is useful for local multi-application tests and as a
  ## contract reference; production deployments should use a shared adapter.
  ## The explicit bound prevents a user-controlled rate-limit key from growing
  ## process memory without limit.
  if maxKeys < 1:
    raise newException(ValueError, "in-memory rate limit maxKeys must be positive")
  new(result)
  result.windows = initTable[string, tuple[started: MonoTime, count: int]]()
  result.maxKeys = maxKeys
  initLock(result.lock)

proc evictExpiredLocked(store: InMemoryRateLimitStore, now: MonoTime,
                        windowSeconds: int) =
  ## TTL cleanup is performed before every operation, so stale keys do not
  ## consume the bounded capacity and no background thread is required.
  var expired: seq[string] = @[]
  for key, window in store.windows:
    let elapsed = int((now - window.started).inMilliseconds div 1000)
    if elapsed >= windowSeconds:
      expired.add(key)
  for key in expired:
    store.windows.del(key)

proc evictOldestLocked(store: InMemoryRateLimitStore) =
  ## Evict the oldest active window deterministically when a new key would
  ## exceed maxKeys. This mirrors common bounded-cache eviction semantics.
  if store.windows.len < store.maxKeys:
    return
  var oldestKey = ""
  var oldestStarted: MonoTime
  var found = false
  for key, window in store.windows:
    if not found or window.started < oldestStarted:
      oldestKey = key
      oldestStarted = window.started
      found = true
  if found:
    store.windows.del(oldestKey)

method consume*(store: InMemoryRateLimitStore, key: string, limit,
                windowSeconds: int): RateLimitDecision {.gcsafe.} =
  if store.isNil or key.len == 0 or limit < 1 or windowSeconds < 1:
    raise newException(ValueError,
      "in-memory rate limit key, limit, and window must be valid")
  acquire(store.lock)
  defer: release(store.lock)
  let now = getMonoTime()
  store.evictExpiredLocked(now, windowSeconds)
  if not store.windows.hasKey(key):
    store.evictOldestLocked()
  var window = store.windows.getOrDefault(key,
    (started: now, count: 0))
  let elapsedSeconds = int((now - window.started).inMilliseconds div 1000)
  if elapsedSeconds >= windowSeconds:
    window = (started: now, count: 0)
  if window.count >= limit:
    result.allowed = false
    result.remaining = 0
    result.retryAfter = max(1, windowSeconds - elapsedSeconds)
    store.windows[key] = window
    return
  result.allowed = true
  inc window.count
  result.remaining = max(0, limit - window.count)
  result.retryAfter = 0
  store.windows[key] = window

proc consumeRateLimit(state: RateLimitState, policy: SecurityPolicy):
    tuple[enabled: bool, available: bool, allowed: bool, remaining: int,
          retryAfter: int] =
  ## Consume one slot from a fixed window. This intentionally uses a simple
  ## fixed-window algorithm so the policy remains deterministic and replaceable
  ## by a distributed store without changing middleware behavior.
  if policy.rateLimitRequests <= 0 or policy.rateLimitWindowSeconds <= 0:
    return (false, true, true, 0, 0)
  if policy.rateLimitStore != nil:
    try:
      let decision = policy.rateLimitStore.consume(policy.rateLimitKey,
        policy.rateLimitRequests, policy.rateLimitWindowSeconds)
      return (true, true, decision.allowed, decision.remaining,
        decision.retryAfter)
    except CatchableError:
      ## A quota backend outage must not silently fail open. The middleware
      ## converts this unavailable result into a retryable 503 response.
      return (true, false, false, 0, 1)
  let elapsedSeconds = int((getMonoTime() - state.windowStarted).inMilliseconds div 1000)
  if elapsedSeconds >= policy.rateLimitWindowSeconds:
    state.windowStarted = getMonoTime()
    state.requestCount = 0
  let remaining = max(0, policy.rateLimitRequests - state.requestCount - 1)
  if state.requestCount >= policy.rateLimitRequests:
    let retryAfter = max(1, policy.rateLimitWindowSeconds - elapsedSeconds)
    return (true, true, false, 0, retryAfter)
  inc state.requestCount
  (true, true, true, remaining, 0)

proc addRateLimitHeaders(response: var Response, policy: SecurityPolicy,
                         remaining: int) =
  ## Expose stable quota information for clients without leaking internal state.
  response.headers["x-ratelimit-limit"] = $policy.rateLimitRequests
  response.headers["x-ratelimit-remaining"] = $remaining

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

proc verifySignedValueWithKeyring*(secrets: openArray[string],
                                   signedValue: string):
    Option[SignedValueVerification] =
  ## Verify against the primary key first, then legacy keys in order. Keeping
  ## the key index in the result makes rotation explicit instead of silently
  ## re-signing every cookie and hiding key rollover behavior from callers.
  for keyIndex, secret in secrets:
    let value = verifySignedValue(secret, signedValue)
    if value.isSome:
      return some(SignedValueVerification(value: value.get(),
        keyIndex: keyIndex, needsRotation: keyIndex > 0))
  none(SignedValueVerification)

proc setSignedCookie*(response: var Response, name, value, secret: string,
                      httpOnly = true, secure = true, sameSite = "Lax",
                      maxAge = -1) =
  ## Signed cookies default to HttpOnly and Secure because they commonly carry
  ## identity or authorization state. Callers must provide an explicit secret.
  response.setCookie(name, signValue(secret, value), httpOnly, secure,
    sameSite, maxAge)

proc setRotatedSignedCookie*(response: var Response, name,
                             primarySecret: string,
                             verification: SignedValueVerification,
                             httpOnly = true, secure = true,
                             sameSite = "Lax", maxAge = -1) =
  ## Re-issue a legacy-key cookie with the current primary key. Callers should
  ## invoke this only when `verification.needsRotation` is true.
  if verification.needsRotation:
    response.setSignedCookie(name, verification.value, primarySecret,
      httpOnly, secure, sameSite, maxAge)

proc signedCookieValue*(request: Request, name, secret: string): Option[string] =
  ## Read and verify one signed cookie without coupling handlers to a server
  ## cookie-jar implementation.
  if not request.cookies.hasKey(name):
    return none(string)
  verifySignedValue(secret, request.cookies[name])

proc sessionSecrets(policy: SessionPolicy): seq[string] =
  ## The primary key is always tried first so rotation metadata is stable.
  result.add(policy.secret)
  for secret in policy.legacySecrets:
    if secret.len > 0 and secret notin result:
      result.add(secret)

proc signedSessionVerification*(request: Request,
                               policy: SessionPolicy):
    Option[SignedValueVerification] =
  ## Expose rotation metadata without exposing cookie serialization to callers.
  if not request.cookies.hasKey(policy.cookieName):
    return none(SignedValueVerification)
  verifySignedValueWithKeyring(policy.sessionSecrets(),
    request.cookies[policy.cookieName])

method authenticate*(backend: AuthBackend,
                     request: Request): Option[AuthContext] {.base, gcsafe.} =
  ## Backends must return no context for invalid credentials; middleware then
  ## applies the same anonymous/401 policy for every credential transport.
  discard backend
  discard request
  raise newException(ValueError, "Auth backend does not implement authenticate")

proc newSessionCookieAuthBackend*(policy: SessionPolicy):
    SessionCookieAuthBackend =
  ## Reuse the existing signed-cookie policy without making middleware know the
  ## cookie serialization details.
  if not policy.enabled or policy.cookieName.strip().len == 0 or
     policy.secret.len == 0:
    raise newException(ValueError, "Session auth backend requires an enabled policy")
  SessionCookieAuthBackend(policy: policy)

proc addAuthBackend*(policy: var SecurityPolicy, backend: AuthBackend) =
  ## Compose credential transports explicitly while preserving the old
  ## `authBackend` field for applications that configure one provider only.
  if backend.isNil:
    raise newException(ValueError, "Authentication backend is required")
  if policy.authBackends.len == 0 and policy.authBackend != nil:
    policy.authBackends.add(policy.authBackend)
    policy.authBackend = nil
  for existing in policy.authBackends:
    if existing == backend:
      raise newException(ValueError, "Duplicate authentication backend")
  policy.authBackends.add(backend)

proc configuredAuthBackends(policy: SecurityPolicy): seq[AuthBackend] =
  ## Normalize singular and plural configuration at the middleware boundary so
  ## all downstream authentication decisions use one deterministic provider
  ## order and one anonymous fallback.
  if policy.authBackend != nil:
    result.add(policy.authBackend)
  for backend in policy.authBackends:
    if backend != nil and backend notin result:
      result.add(backend)

method authenticate*(backend: SessionCookieAuthBackend,
                     request: Request): Option[AuthContext] {.gcsafe.} =
  let verification = signedSessionVerification(request, backend.policy)
  let subject = if verification.isSome: some(verification.get().value)
                else: none(string)
  if subject.isSome and subject.get().strip().len > 0:
    return some(AuthContext(authenticated: true, subject: subject.get()))
  none(AuthContext)

proc newBearerTokenAuthBackend*(secret: string,
                                headerName = "authorization",
                                scheme = "Bearer"): BearerTokenAuthBackend =
  ## Token issuance and verification stay in one adapter so callers cannot
  ## accidentally accept an unsigned value or a different authorization scheme.
  if secret.len < 32 or headerName.strip().len == 0 or scheme.strip().len == 0:
    raise newException(ValueError,
      "Bearer auth backend requires a strong secret, header, and scheme")
  BearerTokenAuthBackend(secret: secret, headerName: headerName,
    scheme: scheme)

proc issueBearerToken*(backend: BearerTokenAuthBackend,
                       subject: string): string =
  ## The returned token is opaque and cookie/header safe; expiry and claims can
  ## be supplied by a future JWT backend without changing AuthBackend callers.
  if backend.isNil or subject.strip().len == 0:
    raise newException(ValueError, "Bearer token subject must not be empty")
  signValue(backend.secret, subject)

method authenticate*(backend: BearerTokenAuthBackend,
                     request: Request): Option[AuthContext] {.gcsafe.} =
  let header = request.header(backend.headerName)
  if header.isNone:
    return none(AuthContext)
  let parts = header.get().strip().splitWhitespace()
  if parts.len != 2 or parts[0].toLowerAscii() != backend.scheme.toLowerAscii():
    return none(AuthContext)
  let subject = verifySignedValue(backend.secret, parts[1])
  if subject.isSome and subject.get().strip().len > 0:
    return some(AuthContext(authenticated: true, subject: subject.get()))
  none(AuthContext)

method isRevoked*(store: JwtRevocationStore, tokenId: string,
                  now: int64): bool {.base, gcsafe.} =
  discard store
  discard tokenId
  discard now
  raise newException(ValueError, "JWT revocation store is not implemented")

method revoke*(store: JwtRevocationStore, tokenId: string,
               expiresAt: int64) {.base, gcsafe.} =
  discard store
  discard tokenId
  discard expiresAt
  raise newException(ValueError, "JWT revocation store is not implemented")

proc newInMemoryJwtRevocationStore*(): InMemoryJwtRevocationStore =
  new(result)
  result.revoked = initTable[string, int64]()
  initLock(result.lock)

method isRevoked*(store: InMemoryJwtRevocationStore, tokenId: string,
                  now: int64): bool {.gcsafe.} =
  if store.isNil or tokenId.len == 0:
    return false
  acquire(store.lock)
  defer: release(store.lock)
  var expired: seq[string] = @[]
  for existing, expiresAt in store.revoked:
    if expiresAt <= now:
      expired.add(existing)
  for existing in expired:
    store.revoked.del(existing)
  store.revoked.hasKey(tokenId)

method revoke*(store: InMemoryJwtRevocationStore, tokenId: string,
               expiresAt: int64) {.gcsafe.} =
  if store.isNil or tokenId.strip().len == 0 or expiresAt <= getTime().toUnix:
    raise newException(ValueError, "JWT revocation requires a live token id and expiry")
  acquire(store.lock)
  defer: release(store.lock)
  store.revoked[tokenId] = expiresAt

proc base64UrlEncode(value: string): string =
  result = encode(value).replace("+", "-").replace("/", "_")
  while result.endsWith("="):
    result.setLen(result.len - 1)

proc base64UrlDecode(value: string): Option[string] =
  if value.len == 0 or value.len mod 4 == 1:
    return none(string)
  for character in value:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      return none(string)
  var padded = value.replace("-", "+").replace("_", "/")
  while padded.len mod 4 != 0:
    padded.add('=')
  try:
    some(decode(padded))
  except CatchableError:
    none(string)

proc newJwtKey*(id, secret: string): JwtKey =
  if id.strip().len == 0 or secret.len < 32:
    raise newException(ValueError, "JWT key requires id and a strong secret")
  JwtKey(id: id, secret: secret)

proc newJwtTokenAuthBackend*(keys: openArray[JwtKey], issuer, audience: string,
                             headerName = "authorization", scheme = "Bearer",
                             clockSkewSeconds: int64 = 0,
                             revocations: JwtRevocationStore = nil):
    JwtTokenAuthBackend =
  if keys.len == 0 or issuer.strip().len == 0 or audience.strip().len == 0 or
      headerName.strip().len == 0 or scheme.strip().len == 0 or
      clockSkewSeconds < 0:
    raise newException(ValueError,
      "JWT backend requires keys, issuer, audience, header, scheme, and valid skew")
  new(result)
  result.keys = @[]
  for key in keys:
    discard newJwtKey(key.id, key.secret)
    for existing in result.keys:
      if existing.id == key.id:
        raise newException(ValueError, "Duplicate JWT key id: " & key.id)
    result.keys.add(key)
  result.issuer = issuer
  result.audience = audience
  result.headerName = headerName
  result.scheme = scheme
  result.clockSkewSeconds = clockSkewSeconds
  result.revocations = revocations

proc jwtKey(backend: JwtTokenAuthBackend, keyId: string): Option[JwtKey] =
  if backend.isNil:
    return none(JwtKey)
  for key in backend.keys:
    if key.id == keyId:
      return some(key)
  none(JwtKey)

proc issueJwtAt*(backend: JwtTokenAuthBackend, subject: string,
                 ttlSeconds, now: int64, tokenId = "",
                 notBefore: int64 = -1): string =
  ## Only the first configured key signs new tokens; older keys verify until
  ## retired from the explicit keyring.
  if backend.isNil or subject.strip().len == 0 or ttlSeconds <= 0:
    raise newException(ValueError, "JWT issuance requires a subject and positive TTL")
  let effectiveNotBefore = if notBefore < 0: now else: notBefore
  let effectiveTokenId = if tokenId.len > 0: tokenId else: hexEncode(urandom(16))
  if effectiveTokenId.contains({' ', '|', '.'}) or effectiveNotBefore > now + ttlSeconds:
    raise newException(ValueError, "JWT token id or not-before claim is invalid")
  let header = base64UrlEncode($(%*{"alg": "HS256", "typ": "JWT",
    "kid": backend.keys[0].id}))
  let payload = base64UrlEncode($(%*{"sub": subject, "iss": backend.issuer,
    "aud": backend.audience, "iat": now, "nbf": effectiveNotBefore,
    "exp": now + ttlSeconds, "jti": effectiveTokenId}))
  let signingInput = header & "." & payload
  signingInput & "." & ($sha256.hmac(backend.keys[0].secret,
    signingInput)).toLowerAscii()

proc issueJwt*(backend: JwtTokenAuthBackend, subject: string,
               ttlSeconds: int64): string =
  issueJwtAt(backend, subject, ttlSeconds, getTime().toUnix)

proc verifyJwtAt*(backend: JwtTokenAuthBackend, token: string,
                  now: int64): Option[JwtClaims] =
  ## Reject malformed, retired, future, expired, wrong issuer/audience, and
  ## revoked credentials with one anonymous result.
  try:
    let parts = token.split('.')
    if backend.isNil or parts.len != 3:
      return none(JwtClaims)
    let headerRaw = base64UrlDecode(parts[0])
    let payloadRaw = base64UrlDecode(parts[1])
    if headerRaw.isNone or payloadRaw.isNone:
      return none(JwtClaims)
    let header = parseJson(headerRaw.get())
    let payload = parseJson(payloadRaw.get())
    if header.kind != JObject or payload.kind != JObject or
        not header.hasKey("alg") or header["alg"].getStr() != "HS256" or
        not header.hasKey("kid") or header["kid"].kind != JString:
      return none(JwtClaims)
    let key = backend.jwtKey(header["kid"].getStr())
    if key.isNone or not constantTimeEquals(parts[2],
        ($sha256.hmac(key.get().secret, parts[0] & "." & parts[1])).toLowerAscii()):
      return none(JwtClaims)
    for required in ["sub", "iss", "aud", "jti"]:
      if not payload.hasKey(required) or payload[required].kind != JString:
        return none(JwtClaims)
    for required in ["iat", "nbf", "exp"]:
      if not payload.hasKey(required) or payload[required].kind != JInt:
        return none(JwtClaims)
    result = some(JwtClaims(subject: payload["sub"].getStr(),
      issuer: payload["iss"].getStr(), audience: payload["aud"].getStr(),
      issuedAt: payload["iat"].getInt(), notBefore: payload["nbf"].getInt(),
      expiresAt: payload["exp"].getInt(), tokenId: payload["jti"].getStr(),
      keyId: key.get().id))
    let claims = result.get()
    if claims.subject.strip().len == 0 or claims.issuer != backend.issuer or
        claims.audience != backend.audience or claims.issuedAt > now + backend.clockSkewSeconds or
        claims.notBefore > now + backend.clockSkewSeconds or
        claims.expiresAt <= now - backend.clockSkewSeconds or
        claims.expiresAt <= claims.issuedAt or claims.tokenId.len == 0:
      return none(JwtClaims)
    if not backend.revocations.isNil and backend.revocations.isRevoked(
        claims.tokenId, now):
      return none(JwtClaims)
    return result
  except CatchableError:
    none(JwtClaims)

method authenticate*(backend: JwtTokenAuthBackend,
                     request: Request): Option[AuthContext] {.gcsafe.} =
  let header = request.header(backend.headerName)
  if header.isNone:
    return none(AuthContext)
  let parts = header.get().strip().splitWhitespace()
  if parts.len != 2 or parts[0].toLowerAscii() != backend.scheme.toLowerAscii():
    return none(AuthContext)
  let claims = verifyJwtAt(backend, parts[1], getTime().toUnix)
  if claims.isSome:
    return some(AuthContext(authenticated: true, subject: claims.get().subject))
  none(AuthContext)

proc bindSession*(request: var Request, policy: SessionPolicy): bool =
  ## Verify and bind one signed session subject without exposing cookie format
  ## to handlers. Invalid credentials always become anonymous rather than
  ## leaking whether a cookie was malformed, expired, or signed by another
  ## deployment key.
  request.auth = AuthContext(authenticated: false, subject: "")
  if not policy.enabled or policy.secret.len == 0:
    return false
  let verification = signedSessionVerification(request, policy)
  if verification.isSome and verification.get().value.strip().len > 0:
    request.auth = AuthContext(authenticated: true,
      subject: verification.get().value)
    return true
  false

proc setSessionCookie*(response: var Response, policy: SessionPolicy,
                       subject: string, maxAge = -1) =
  ## Issue a framework-owned signed session cookie after an auth flow succeeds.
  if not policy.enabled or policy.secret.len == 0:
    raise newException(ValueError, "Session policy is not configured")
  if subject.strip().len == 0:
    raise newException(ValueError, "Session subject must not be empty")
  response.setSignedCookie(policy.cookieName, subject, policy.secret,
    httpOnly = true, secure = policy.secureCookie, sameSite = "Lax", maxAge)

proc clearSessionCookie*(response: var Response, policy: SessionPolicy) =
  ## Expire a session without allowing callers to construct unsafe cookie text.
  response.setCookie(policy.cookieName, "", httpOnly = true,
    secure = policy.secureCookie, sameSite = "Lax", maxAge = 0)

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

proc submittedCsrfToken(request: Request,
                        policy: SecurityPolicy): Option[string] =
  ## API clients echo the token in a header, while ordinary HTML forms cannot
  ## set custom headers. Accept the framework field name and the conventional
  ## `csrf` alias from parsed form bodies without weakening the signed
  ## double-submit cookie comparison below.
  let headerToken = request.header(policy.csrfHeaderName)
  if headerToken.isSome:
    return headerToken
  let parsed = request.parseRequestBody()
  if not parsed.valid or parsed.encoding notin
      {beFormUrlEncoded, beMultipart}:
    return none(string)
  for fieldName in [policy.csrfHeaderName, "csrf"]:
    if parsed.fields.hasKey(fieldName):
      return some(parsed.fields[fieldName])
  none(string)

proc addCsrfCookie(response: var Response, policy: SecurityPolicy,
                   token: string) =
  ## HttpOnly is intentionally false: browser code must echo this token in the
  ## request header, while SameSite=Lax and Secure remain safe defaults.
  response.setCookie(policy.csrfCookieName, token, httpOnly = false,
    secure = policy.csrfCookieSecure, sameSite = "Lax")

proc securityMiddleware*(policy: SecurityPolicy): Middleware =
  ## Establish effective transport metadata before validating Host. This keeps
  ## TLS termination at the adapter boundary while preventing forged forwarded
  ## headers from reaching handlers.
  let rateLimitState = newRateLimitState()
  result = proc(request: Request, next: Handler): Future[Response] {.async, gcsafe.} =
    var requestWithProxy = request
    requestWithProxy.scheme = policy.effectiveScheme(request)
    let effectiveHostValue = policy.effectiveHost(request)
    if effectiveHostValue.isSome:
      requestWithProxy.headers["host"] = effectiveHostValue.get()
    if policy.requireHttps and requestWithProxy.scheme != "https":
      var rejected = textResponse("HTTPS Required", Http400)
      addSecurityHeaders(rejected, policy)
      return rejected
    let host = requestWithProxy.header("host")
    if policy.allowedHosts.len > 0 and
       (host.isNone or not allowedHost(policy, host.get())):
      var rejected = textResponse("Invalid Host", Http400)
      addSecurityHeaders(rejected, policy)
      return rejected
    let origin = requestWithProxy.header("origin")
    if origin.isSome and policy.allowedOrigins.len > 0 and
       not allowedOrigin(policy, origin.get()):
      var rejected = textResponse("Origin Not Allowed", Http403)
      addSecurityHeaders(rejected, policy)
      return rejected
    if policy.maxBodyBytes > 0 and requestWithProxy.body.len > policy.maxBodyBytes:
      var rejected = textResponse("Request Entity Too Large", Http413)
      addSecurityHeaders(rejected, policy)
      return rejected
    var requestWithAuth = requestWithProxy
    var sessionRotation = none(SignedValueVerification)
    let authBackends = policy.configuredAuthBackends()
    if authBackends.len > 0:
      var authentication = none(AuthContext)
      for backend in authBackends:
        let candidate = backend.authenticate(requestWithAuth)
        if candidate.isSome:
          authentication = candidate
          break
      requestWithAuth.auth = if authentication.isSome:
        authentication.get()
      else:
        AuthContext(authenticated: false, subject: "")
      ## A composed provider list may still contain the session backend. Keep
      ## legacy-key rotation independent from which provider authenticated the
      ## request so adding bearer support cannot silently disable cookie
      ## maintenance for browser sessions.
      if policy.session.enabled:
        sessionRotation = signedSessionVerification(requestWithAuth,
          policy.session)
      let authenticated = authentication.isSome
      ## CORS preflight has no application credentials by design; rejecting it
      ## here would prevent browsers from discovering the authenticated route.
      let isCorsPreflight = requestWithProxy.httpMethod == "OPTIONS" and origin.isSome
      if policy.session.requireAuthentication and not authenticated and
         not isCorsPreflight:
        var rejected = textResponse("Authentication Required", Http401)
        addSecurityHeaders(rejected, policy)
        return rejected
    elif policy.session.enabled:
      if policy.session.secret.len == 0 or
         policy.session.cookieName.strip().len == 0:
        var rejected = textResponse("Session Policy Misconfigured", Http500)
        addSecurityHeaders(rejected, policy)
        return rejected
      sessionRotation = signedSessionVerification(requestWithAuth, policy.session)
      let authenticated = requestWithAuth.bindSession(policy.session)
      ## CORS preflight has no application credentials by design; rejecting it
      ## here would prevent browsers from discovering the authenticated route.
      let isCorsPreflight = requestWithProxy.httpMethod == "OPTIONS" and origin.isSome
      if policy.session.requireAuthentication and not authenticated and
         not isCorsPreflight:
        var rejected = textResponse("Authentication Required", Http401)
        addSecurityHeaders(rejected, policy)
        return rejected
    let rateLimit = consumeRateLimit(rateLimitState, policy)
    if rateLimit.enabled and not rateLimit.available:
      var rejected = textResponse("Rate Limit Store Unavailable", Http503)
      rejected.headers["retry-after"] = $rateLimit.retryAfter
      addSecurityHeaders(rejected, policy)
      return rejected
    if rateLimit.enabled and not rateLimit.allowed:
      var rejected = textResponse("Too Many Requests", Http429)
      addRateLimitHeaders(rejected, policy, rateLimit.remaining)
      rejected.headers["retry-after"] = $rateLimit.retryAfter
      addSecurityHeaders(rejected, policy)
      return rejected
    if policy.csrfEnabled and policy.csrfSecret.len > 0:
      ## Bind one token before the handler renders HTML. Existing valid cookie
      ## tokens are reused; missing or invalid tokens are replaced only after
      ## the response is produced, keeping form hidden input and cookie aligned.
      let existingToken = requestWithAuth.cookies.getOrDefault(
        policy.csrfCookieName)
      requestWithAuth.csrfToken = if existingToken.len > 0 and
          verifyCsrfToken(policy, existingToken): existingToken
        else: csrfToken(policy)
    if policy.csrfEnabled:
      if policy.csrfSecret.len == 0:
        var rejected = textResponse("CSRF Policy Misconfigured", Http500)
        addSecurityHeaders(rejected, policy)
        return rejected
      if csrfProtectedMethod(requestWithProxy.httpMethod):
        let cookieToken = requestWithProxy.cookies.getOrDefault(policy.csrfCookieName)
        let submittedToken = requestWithProxy.submittedCsrfToken(policy)
        if cookieToken.len == 0 or submittedToken.isNone or
           not verifyCsrfToken(policy, cookieToken) or
           not constantTimeEquals(cookieToken, submittedToken.get()):
          var rejected = textResponse("CSRF Validation Failed", Http403)
          addSecurityHeaders(rejected, policy)
          return rejected
    if requestWithProxy.httpMethod == "OPTIONS" and origin.isSome:
      var preflight = newResponse(Http204)
      addCorsHeaders(preflight, policy, origin.get())
      addSecurityHeaders(preflight, policy)
      return preflight
    var response = await next(requestWithAuth)
    if rateLimit.enabled:
      addRateLimitHeaders(response, policy, rateLimit.remaining)
    if policy.csrfEnabled and requestWithAuth.csrfToken.len > 0 and
       requestWithProxy.cookies.getOrDefault(policy.csrfCookieName) !=
         requestWithAuth.csrfToken:
      addCsrfCookie(response, policy, requestWithAuth.csrfToken)
    if sessionRotation.isSome and sessionRotation.get().needsRotation:
      response.setRotatedSignedCookie(policy.session.cookieName,
        policy.session.secret, sessionRotation.get(), httpOnly = true,
        secure = policy.session.secureCookie, sameSite = "Lax")
    if origin.isSome and policy.allowedOrigins.len > 0:
      addCorsHeaders(response, policy, origin.get())
    addSecurityHeaders(response, policy)
    return response

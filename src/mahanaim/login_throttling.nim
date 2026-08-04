## Authentication-attempt throttling contract.
##
## Authentication backends decide whether credentials are valid; this module
## only limits repeated attempts. Keeping the concerns separate allows a
## distributed adapter to replace the in-memory implementation without
## changing login handlers.

import std/[locks, monotimes, strutils, tables, times]

type
  LoginThrottleDecision* = object
    allowed*: bool
    failures*: int
    retryAfterSeconds*: int

  LoginThrottleCounterResult* = object
    ## A shared backend returns the current count and server-side TTL together.
    count*: int
    ttlSeconds*: int

  LoginThrottleCounterClient* = ref object of RootObj
    ## Separate read/increment/reset operations preserve login semantics; the
    ## generic rate-limit counter cannot safely stand in for this contract.

  LoginThrottleStore* = ref object of RootObj
    ## Backend-neutral boundary for process-local or distributed stores.

  LoginThrottleState = object
    windowStarted: MonoTime
    failures: int

  InMemoryLoginThrottle* = ref object of LoginThrottleStore
    maxFailures*: int
    windowSeconds*: int
    states: Table[string, LoginThrottleState]
    lock: Lock

  DistributedLoginThrottle* = ref object of LoginThrottleStore
    client*: LoginThrottleCounterClient
    maxFailures*: int
    windowSeconds*: int
    maxRetries*: int

method readFailureCount*(client: LoginThrottleCounterClient, key: string,
                         windowSeconds: int): LoginThrottleCounterResult {.base, gcsafe.} =
  discard client
  discard key
  discard windowSeconds
  raise newException(ValueError, "Login throttle counter read is not implemented")

method incrementFailure*(client: LoginThrottleCounterClient, key: string,
                         windowSeconds: int): LoginThrottleCounterResult {.base, gcsafe.} =
  discard client
  discard key
  discard windowSeconds
  raise newException(ValueError, "Login throttle counter increment is not implemented")

method resetFailures*(client: LoginThrottleCounterClient, key: string) {.base, gcsafe.} =
  discard client
  discard key
  raise newException(ValueError, "Login throttle counter reset is not implemented")

method checkAttempt*(store: LoginThrottleStore,
                     key: string): LoginThrottleDecision {.base, gcsafe.} =
  ## A missing adapter must fail closed rather than silently allowing logins.
  discard store
  discard key
  raise newException(ValueError, "Login throttle store is not implemented")

method recordFailure*(store: LoginThrottleStore, key: string) {.base, gcsafe.} =
  discard store
  discard key
  raise newException(ValueError, "Login throttle store is not implemented")

method recordSuccess*(store: LoginThrottleStore, key: string) {.base, gcsafe.} =
  discard store
  discard key
  raise newException(ValueError, "Login throttle store is not implemented")

proc newInMemoryLoginThrottle*(maxFailures = 5,
                               windowSeconds = 60): InMemoryLoginThrottle =
  ## The bounded process-local adapter is suitable for one instance and tests;
  ## multi-instance deployments should provide a shared store implementation.
  if maxFailures <= 0 or windowSeconds <= 0:
    raise newException(ValueError,
      "Login throttle limits must be positive")
  new(result)
  result.maxFailures = maxFailures
  result.windowSeconds = windowSeconds
  result.states = initTable[string, LoginThrottleState]()
  initLock(result.lock)

proc validateKey(key: string) =
  if key.strip().len == 0:
    raise newException(ValueError, "Login throttle key must not be empty")

proc newDistributedLoginThrottle*(client: LoginThrottleCounterClient,
                                  maxFailures = 5, windowSeconds = 60,
                                  maxRetries = 1): DistributedLoginThrottle =
  ## Bounded retries avoid blocking login handlers indefinitely while an
  ## unavailable shared store remains fail-closed through raised errors.
  if client.isNil or maxFailures <= 0 or windowSeconds <= 0 or maxRetries < 0:
    raise newException(ValueError, "Invalid distributed login throttle configuration")
  DistributedLoginThrottle(client: client, maxFailures: maxFailures,
    windowSeconds: windowSeconds, maxRetries: maxRetries)

proc readRemote(store: DistributedLoginThrottle, key: string):
    LoginThrottleCounterResult =
  var lastError: ref CatchableError
  for _ in 0 .. store.maxRetries:
    try:
      return store.client.readFailureCount(key, store.windowSeconds)
    except CatchableError as error:
      lastError = error
  raise lastError

proc incrementRemote(store: DistributedLoginThrottle, key: string):
    LoginThrottleCounterResult =
  var lastError: ref CatchableError
  for _ in 0 .. store.maxRetries:
    try:
      return store.client.incrementFailure(key, store.windowSeconds)
    except CatchableError as error:
      lastError = error
  raise lastError

method checkAttempt*(store: DistributedLoginThrottle,
                     key: string): LoginThrottleDecision {.gcsafe.} =
  validateKey(key)
  let counter = store.readRemote(key)
  result.failures = max(0, counter.count)
  result.allowed = result.failures < store.maxFailures
  if not result.allowed:
    result.retryAfterSeconds = max(1, counter.ttlSeconds)

method recordFailure*(store: DistributedLoginThrottle, key: string) {.gcsafe.} =
  validateKey(key)
  discard store.incrementRemote(key)

method recordSuccess*(store: DistributedLoginThrottle, key: string) {.gcsafe.} =
  validateKey(key)
  store.client.resetFailures(key)

proc refreshState(store: InMemoryLoginThrottle, key: string,
                  now: MonoTime): LoginThrottleState =
  if store.states.hasKey(key):
    result = store.states[key]
    let elapsedMs = (now - result.windowStarted).inMilliseconds
    if elapsedMs >= int64(store.windowSeconds) * 1000:
      result = LoginThrottleState(windowStarted: now, failures: 0)
  else:
    result = LoginThrottleState(windowStarted: now, failures: 0)

method checkAttempt*(store: InMemoryLoginThrottle,
                     key: string): LoginThrottleDecision {.gcsafe.} =
  ## Reads never increment counters, so callers can check before credential
  ## verification and record exactly one outcome afterward.
  validateKey(key)
  acquire(store.lock)
  try:
    let now = getMonoTime()
    let state = store.refreshState(key, now)
    store.states[key] = state
    result.failures = state.failures
    result.allowed = state.failures < store.maxFailures
    if not result.allowed:
      let elapsedMs = (now - state.windowStarted).inMilliseconds
      result.retryAfterSeconds = max(1,
        store.windowSeconds - int(elapsedMs div 1000))
  finally:
    release(store.lock)

method recordFailure*(store: InMemoryLoginThrottle, key: string) {.gcsafe.} =
  ## Failed attempts are bounded by maxFailures; the next check denies access.
  validateKey(key)
  acquire(store.lock)
  try:
    var state = store.refreshState(key, getMonoTime())
    if state.failures < store.maxFailures:
      inc state.failures
    store.states[key] = state
  finally:
    release(store.lock)

method recordSuccess*(store: InMemoryLoginThrottle, key: string) {.gcsafe.} =
  ## A successful authentication clears the subject's failure window.
  validateKey(key)
  acquire(store.lock)
  try:
    store.states.del(key)
  finally:
    release(store.lock)

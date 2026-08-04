## Contract tests for the first Mahanaim vertical slice.
##
## These tests exercise the framework without opening a network socket. That
## keeps failures deterministic while still covering the same dispatch pipeline
## a future Prologue/ASGI adapter will call.

import std/[asyncdispatch, asyncnet, httpcore, json, options, os, osproc, strutils, tables, times,
            unittest, uri]
import std/net
import std/httpclient as hc
import std/concurrency/atomics
import pkg/cookiejar
import prologue/core/nativesettings as prologueSettings
import prologue/core/httpcore/httplogue
import prologue/core/request except Request
import prologue/mocking/mocking
import mahanaim

type MacroUser = object
  id: int
  email: string
  active: bool

type CreateProfileDto = object
  displayName: string
  age: int

type ProfileResponseDto = object
  id: int
  displayName: string

type FakeDependencyService = ref object of DependencyService
type FakeDatabaseAdapter = ref object of DatabaseAdapter
  events: seq[string]

type FakePasswordHasher = ref object of PasswordHasher

proc fakePasswordHash(password: string): string = "fake$" & password

method hashPassword(hasher: FakePasswordHasher, password: string): string
    {.gcsafe.} =
  discard hasher
  fakePasswordHash(password)

method verifyPassword(hasher: FakePasswordHasher, password, encoded: string): bool
    {.gcsafe.} =
  discard hasher
  fakePasswordHash(password) == encoded

method passwordNeedsRehash(hasher: FakePasswordHasher, encoded: string): bool
    {.gcsafe.} =
  discard hasher
  encoded == "fake$legacy"

type RespFixtureState = object
  ## Only copy-safe state crosses the native thread boundary.
  port: Atomic[int]
  ready: Atomic[bool]
  received: Atomic[bool]

type RedisReconnectFixtureState = object
  ## The fixture deliberately drops the first connection to exercise the
  ## adapter's socket disposal and bounded-retry reconnect contract.
  port: Atomic[int]
  ready: Atomic[bool]
  connections: Atomic[int]

proc discardResetDelivery(subject, token: string) {.gcsafe.} =
  ## The route test focuses on token semantics; delivery is an adapter seam.
  discard subject
  discard token

proc runRespFixture(state: ptr RespFixtureState) {.thread, gcsafe.} =
  ## Minimal loopback RESP server: enough protocol surface to test the real
  ## socket adapter without requiring an externally installed Redis daemon.
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0))
  server.listen()
  let local = server.getLocalAddr()
  state.port.store(local[1].int)
  state.ready.store(true)
  var client: owned(Socket)
  server.accept(client)
  var command = ""
  while not command.endsWith("$2\r\n60\r\n") and command.len < 4096:
    command.add(client.recv(1, 5000))
  if command.startsWith("*5\r\n$4\r\nEVAL\r\n"):
    state.received.store(true)
  client.send("*2\r\n:4\r\n:56\r\n")
  client.close()
  server.close()

proc runRedisReconnectFixture(state: ptr RedisReconnectFixtureState) {.thread, gcsafe.} =
  ## The first accepted connection receives a valid command and then closes
  ## without a response; the second connection returns a normal RESP result.
  ## This models a transient peer/network failure without requiring Redis.
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0))
  server.listen()
  let local = server.getLocalAddr()
  state.port.store(local[1].int)
  state.ready.store(true)
  for connectionIndex in 1 .. 2:
    var client: owned(Socket)
    server.accept(client)
    var command = ""
    while not command.endsWith("$2\r\n60\r\n") and command.len < 4096:
      command.add(client.recv(1, 5000))
    discard command
    state.connections.store(connectionIndex)
    if connectionIndex == 2:
      client.send("*2\r\n:1\r\n:60\r\n")
    client.close()
  server.close()

proc newFakeDependencyService(): DependencyService {.gcsafe.} =
  FakeDependencyService()

method begin(adapter: FakeDatabaseAdapter) =
  adapter.events.add("begin")

method commit(adapter: FakeDatabaseAdapter) =
  adapter.events.add("commit")

method rollback(adapter: FakeDatabaseAdapter) =
  adapter.events.add("rollback")

type FakeRateLimitCounterClient = ref object of RateLimitCounterClient
  calls: int
  failuresRemaining: int
  count: int

method incrementFixedWindow(client: FakeRateLimitCounterClient, key: string,
                            windowSeconds: int): RateLimitCounterResult =
  ## Test double for an atomic Redis/Valkey INCR+EXPIRE response.
  discard key
  inc client.calls
  if client.failuresRemaining > 0:
    dec client.failuresRemaining
    raise newException(ValueError, "remote counter unavailable")
  inc client.count
  RateLimitCounterResult(count: client.count, ttlSeconds: windowSeconds)

type FakeLoginThrottleCounterClient = ref object of LoginThrottleCounterClient
  count: int
  ttl: int
  readFailures: int
  incrementFailures: int
  resets: int

method readFailureCount(client: FakeLoginThrottleCounterClient, key: string,
                        windowSeconds: int): LoginThrottleCounterResult =
  discard key
  discard windowSeconds
  if client.readFailures > 0:
    dec client.readFailures
    raise newException(ValueError, "login counter read unavailable")
  LoginThrottleCounterResult(count: client.count, ttlSeconds: client.ttl)

method incrementFailure(client: FakeLoginThrottleCounterClient, key: string,
                        windowSeconds: int): LoginThrottleCounterResult =
  discard key
  discard windowSeconds
  if client.incrementFailures > 0:
    dec client.incrementFailures
    raise newException(ValueError, "login counter increment unavailable")
  inc client.count
  LoginThrottleCounterResult(count: client.count, ttlSeconds: client.ttl)

method resetFailures(client: FakeLoginThrottleCounterClient, key: string) =
  discard key
  client.count = 0
  inc client.resets

suite "Mahanaim core contracts":
  test "request and response value objects have safe defaults":
    let request = newRequest("get", "/health")
    check request.httpMethod == "GET"
    check request.path == "/health"
    check request.body == ""

    let response = textResponse("ok")
    check response.status == Http200
    check response.header("Content-Type").get() == "text/plain; charset=utf-8"

  test "response constructors expose file representation safely":
    let path = getTempDir() / "mahanaim-response-file.txt"
    writeFile(path, "downloaded")
    defer:
      if fileExists(path):
        removeFile(path)
    let response = fileResponse(path, "text/plain", Http201)
    check response.status == Http201
    check response.representation == rrFile
    check response.filePath == path
    check response.body == "downloaded"
    check response.header("content-type").get() == "text/plain"
    expect ValueError:
      discard fileResponse("")
    expect IOError:
      discard fileResponse(path & ".missing")

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

  test "cancelled sync request does not enter user handler":
    let app = newApplication()
    var invoked = false
    proc syncHandler(request: Request): mahanaim.Response {.gcsafe.} =
      discard request
      invoked = true
      textResponse("should not run")
    app.getSync("/cancelled-sync", "cancelled-sync", syncHandler)
    var request = newRequest("GET", "/cancelled-sync")
    request.cancellation.cancel()
    let response = waitFor app.dispatch(request)
    check response.status == Http408
    check response.body == "Request cancelled"
    check not invoked

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

  test "running sync work can observe atomic cooperative cancellation":
    ## A timeout cannot safely terminate a native worker. The supported
    ## backend policy is to publish cancellation atomically and let blocking
    ## work exit at an explicit safe point supplied by the handler.
    let executor = newThreadPoolExecutor(pollIntervalMs = 1)
    var cancelled: Atomic[bool]
    cancelled.store(false)
    let pending = executor.execute(proc(): mahanaim.Response {.gcsafe.} =
      while not cancelled.load():
        sleep(1)
      textResponse("worker observed cancellation"))
    waitFor sleepAsync(10)
    cancelled.store(true)
    let response = waitFor pending
    check response.body == "worker observed cancellation"

  test "executor detects blocking work and applies backend cancellation policy":
    ## Detection and cancellation are separate hooks: diagnostics can be
    ## enabled without changing behavior, while a backend may opt into a
    ## stronger cancellation operation when it can prove that operation safe.
    var detected: Atomic[bool]
    var backendCalled: Atomic[bool]
    detected.store(false)
    backendCalled.store(false)
    var policy = defaultExecutionPolicy()
    policy.blockingDetectionMs = 3
    policy.forceCancellationAfterMs = 8
    let app = newApplication(defaultConfig(), defaultSecurityPolicy(), policy)
    ## Hooks belong to the executor adapter, not the copied application policy;
    ## this keeps closure ownership out of the ORC-managed policy value.
    app.executor.hooks.onBlockingDetected = proc(_: int) {.gcsafe.} = detected.store(true)
    app.executor.hooks.backendCancellation = proc(_: CancellationToken): bool {.gcsafe.} =
      backendCalled.store(true)
      true
    proc slow(request: Request): mahanaim.Response {.gcsafe.} =
      while not request.isCancelled():
        sleep(1)
      textResponse("cancelled by executor policy")
    app.getSync("/executor-policy", "executor-policy", slow)
    let response = waitFor app.dispatch(newRequest("GET", "/executor-policy"))
    check response.body == "cancelled by executor policy"
    check detected.load()
    check backendCalled.load()

  test "thread pool executor propagates worker failures":
    let executor = newThreadPoolExecutor()
    proc failJob(): mahanaim.Response {.gcsafe.} =
      raise newException(ValueError, "worker failure")
    expect ValueError:
      discard waitFor executor.execute(failJob)

  test "executor job registry survives repeated application lifecycles":
    ## Regression coverage for the taskpool/GC boundary: applications are
    ## short-lived values, but the native worker pool is process-owned.
    for index in 0 ..< 24:
      let app = newApplication()
      proc repeated(request: Request): mahanaim.Response {.gcsafe.} =
        discard request
        textResponse("iteration")
      app.getSync("/repeated", "repeated-" & $index, repeated)
      let response = waitFor app.dispatch(newRequest("GET", "/repeated"))
      check response.status == Http200
      check response.body == "iteration"

  test "thread pool executor rejects work beyond its configured capacity":
    let executor = newThreadPoolExecutor(pollIntervalMs = 1, maxConcurrentJobs = 1)
    proc slowJob(): mahanaim.Response {.gcsafe.} =
      sleep(100)
      textResponse("slow")
    let first = executor.execute(slowJob)
    expect FrameworkError:
      discard waitFor executor.execute(proc(): mahanaim.Response {.gcsafe.} =
        textResponse("rejected"))
    check first.isNil == false
    check (waitFor first).body == "slow"

  test "executor queue wait absorbs a short capacity burst":
    let executor = newThreadPoolExecutor(
      pollIntervalMs = 1, maxConcurrentJobs = 1, queueWaitMs = 80)
    proc shortJob(): mahanaim.Response {.gcsafe.} =
      sleep(20)
      textResponse("first")
    let first = executor.execute(shortJob)
    waitFor sleepAsync(2)
    let second = executor.execute(proc(): mahanaim.Response {.gcsafe.} =
      textResponse("second"))
    check (waitFor first).body == "first"
    check (waitFor second).body == "second"

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

  test "negative executor capacity is rejected by pre-flight checks":
    var config = defaultConfig()
    config.executorMaxConcurrentJobs = -1
    let report = checkConfig(config)
    check not report.passed
    check report.issues[0].code == "config.executor-capacity.negative"

  test "invalid executor cancellation policy is rejected by pre-flight checks":
    var policy = defaultExecutionPolicy()
    policy.blockingDetectionMs = -1
    let report = checkExecution(initRouter(), policy)
    check not report.passed
    check report.issues[0].code == "execution.blocking-detection.negative"

    policy.queueWaitMs = -1
    let queueReport = checkExecution(initRouter(), policy)
    check not queueReport.passed
    check queueReport.issues[^1].code == "execution.queue-wait.negative"

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

  test "plugin manifest records registration phase and rejects duplicates":
    let app = newApplication()
    proc installManifest(app: Application) {.gcsafe.} =
      discard app
    let manifest = PluginManifest(name: "audit", version: "1.0.0",
      phase: pluginMiddleware, dependencies: @[])
    app.use(newPlugin(manifest, installManifest))
    check app.pluginManifests.len == 1
    check app.pluginManifests[0].phase == pluginMiddleware
    expect ValueError:
      app.use(newPlugin(manifest, installManifest))
    expect ValueError:
      discard newPlugin(PluginManifest(name: "", version: "1.0.0"),
        installManifest)

  test "plugin dependencies resolve deterministically and reject invalid graphs":
    let dependency = PluginManifest(name: "database", version: "1.0.0",
      phase: pluginStorage, dependencies: @[])
    let dependent = PluginManifest(name: "admin", version: "1.0.0",
      phase: pluginAdmin, dependencies: @["database"])
    let ordered = resolvePluginManifests([dependent, dependency])
    check ordered.len == 2
    check ordered[0].name == "database"
    check ordered[1].name == "admin"
    expect ValueError:
      discard resolvePluginManifests([dependent])
    let cycleA = PluginManifest(name: "a", version: "1.0.0",
      phase: pluginRoutes, dependencies: @["b"])
    let cycleB = PluginManifest(name: "b", version: "1.0.0",
      phase: pluginRoutes, dependencies: @["a"])
    expect ValueError:
      discard resolvePluginManifests([cycleA, cycleB])

  test "command and admin extension points reject duplicate registrations":
    let app = newApplication()
    proc command(arguments: seq[string]): int {.gcsafe.} =
      check arguments == @["--dry-run"]
      7
    app.registerCommand(CommandDefinition(name: "migrate",
      description: "Apply migrations", handler: command))
    check app.runCommand("migrate", ["--dry-run"]) == 7
    expect ValueError:
      app.registerCommand(CommandDefinition(name: "migrate", handler: command))
    expect ValueError:
      discard app.runCommand("missing", @[])
    var installed = false
    proc installAdmin(app: Application) {.gcsafe.} =
      discard app
      installed = true
    app.registerAdminExtension(AdminExtension(name: "users", install: installAdmin))
    check installed
    expect ValueError:
      app.registerAdminExtension(AdminExtension(name: "users", install: installAdmin))

  test "DI container caches application scope and recreates task scope":
    let app = newApplication()
    app.provide("singleton", dependencyApplication, newFakeDependencyService)
    app.provide("task", dependencyTask, newFakeDependencyService)
    let first = app.resolve("singleton")
    check first == app.resolve("singleton")
    check app.resolve("task") != app.resolve("task")
    check app.services.hasDependency("singleton")
    expect ValueError:
      discard app.resolve("missing")
    expect ValueError:
      app.provide("singleton", dependencyApplication, newFakeDependencyService)

  test "background jobs use executor and bounded asynchronous retries":
    let app = newApplication()
    let queue = newBackgroundJobQueue(app.executor,
      JobRetryPolicy(maxAttempts: 2, delayMs: 0))
    let result = waitFor queue.enqueue(proc() {.gcsafe.} = discard)
    check result.succeeded
    check result.attempts == 1
    let failed = waitFor queue.enqueue(proc() {.gcsafe.} =
      raise newException(ValueError, "permanent job failure"))
    check not failed.succeeded
    check failed.attempts == 2
    expect ValueError:
      discard newBackgroundJobQueue(app.executor,
        JobRetryPolicy(maxAttempts: 0, delayMs: 0))

  test "background jobs honor idempotency claims and release failed keys":
    let app = newApplication()
    let idempotency = newInMemoryIdempotencyStore()
    let queue = newBackgroundJobQueue(app.executor,
      JobRetryPolicy(maxAttempts: 1, delayMs: 0), idempotency)
    var executions: Atomic[int]
    executions.store(0)
    proc countedJob() {.gcsafe.} =
      discard executions.fetchAdd(1)
    let first = waitFor queue.enqueueIdempotent("email:42", countedJob)
    let duplicate = waitFor queue.enqueueIdempotent("email:42", countedJob)
    check first.succeeded
    check not first.deduplicated
    check duplicate.succeeded
    check duplicate.deduplicated
    check duplicate.attempts == 0
    check executions.load() == 1

    proc failedJob() {.gcsafe.} =
      raise newException(ValueError, "retryable failure")
    let failed = waitFor queue.enqueueIdempotent("email:retry", failedJob)
    let retried = waitFor queue.enqueueIdempotent("email:retry", countedJob)
    check not failed.succeeded
    check retried.succeeded
    expect ValueError:
      discard waitFor queue.enqueueIdempotent("", countedJob)

    let journalPath = getTempDir() / "mahanaim_idempotency.journal"
    if fileExists(journalPath):
      removeFile(journalPath)
    defer:
      if fileExists(journalPath):
        removeFile(journalPath)
    let durableFirst = newFileIdempotencyStore(journalPath)
    check durableFirst.claim("restart:42")
    let durableAfterRestart = newFileIdempotencyStore(journalPath)
    check not durableAfterRestart.claim("restart:42")
    durableAfterRestart.release("restart:42")
    let durableRetry = newFileIdempotencyStore(journalPath)
    check durableRetry.claim("restart:42")
    expect ValueError:
      discard durableRetry.claim("bad\tkey")

    let sqlitePath = getTempDir() / "mahanaim_idempotency.sqlite"
    if fileExists(sqlitePath):
      removeFile(sqlitePath)
    defer:
      if fileExists(sqlitePath):
        removeFile(sqlitePath)
    let sqliteFirst = newSqliteIdempotencyStore(sqlitePath)
    let sqliteSecond = newSqliteIdempotencyStore(sqlitePath)
    defer:
      sqliteFirst.close()
      sqliteSecond.close()
    check sqliteFirst.claim("multi-process:42")
    check not sqliteSecond.claim("multi-process:42")
    sqliteSecond.release("multi-process:42")
    check sqliteFirst.claim("multi-process:42")

    let jobsPath = getTempDir() / "mahanaim_durable_jobs.sqlite"
    if fileExists(jobsPath):
      removeFile(jobsPath)
    defer:
      if fileExists(jobsPath):
        removeFile(jobsPath)
    let durableJobs = newSqliteDurableJobStore(jobsPath)
    durableJobs.enqueue("job-1", "email", "{\"to\":\"a@example.com\"}")
    let claimed = durableJobs.claimNext()
    check claimed.isSome
    check claimed.get().kind == "email"
    check claimed.get().payload.contains("a@example.com")
    check claimed.get().attempts == 1
    durableJobs.complete(claimed.get().id)
    check durableJobs.claimNext().isNone
    durableJobs.enqueue("job-2", "email", "retry")
    let interrupted = durableJobs.claimNext().get()
    check interrupted.status == djsProcessing
    durableJobs.close()
    let recoveredJobs = newSqliteDurableJobStore(jobsPath)
    recoveredJobs.recoverProcessing()
    let recovered = recoveredJobs.claimNext().get()
    check recovered.id == "job-2"
    check recovered.attempts == 2
    recoveredJobs.complete(recovered.id)
    recoveredJobs.close()

  test "external durable job store delegates state transitions to application transport":
    var enqueued: Atomic[int]
    var claimed: Atomic[int]
    var completed: Atomic[int]
    var released: Atomic[int]
    var recovered: Atomic[int]
    var closed: Atomic[int]
    enqueued.store(0)
    claimed.store(0)
    completed.store(0)
    released.store(0)
    recovered.store(0)
    closed.store(0)
    let store = newExternalDurableJobStore(
      proc(id, kind, payload: string) {.gcsafe.} =
        check id == "external-1"
        check kind == "email"
        check payload == "payload"
        discard enqueued.fetchAdd(1),
      proc(): Option[DurableJobRecord] {.gcsafe.} =
        discard claimed.fetchAdd(1)
        some(DurableJobRecord(id: "external-1", kind: "email",
          payload: "payload", status: djsProcessing, attempts: 1)),
      proc(id: string) {.gcsafe.} =
        check id == "external-1"
        discard completed.fetchAdd(1),
      proc(id: string) {.gcsafe.} =
        check id == "external-1"
        discard released.fetchAdd(1),
      proc() {.gcsafe.} = discard recovered.fetchAdd(1),
      proc() {.gcsafe.} = discard closed.fetchAdd(1))
    store.enqueue("external-1", "email", "payload")
    check store.claimNext().get().id == "external-1"
    store.complete("external-1")
    store.release("external-1")
    store.recoverProcessing()
    store.close()
    check enqueued.load() == 1
    check claimed.load() == 1
    check completed.load() == 1
    check released.load() == 1
    check recovered.load() == 1
    check closed.load() == 1

  test "durable job runner dispatches named handlers through the executor":
    let app = newApplication()
    let queue = newBackgroundJobQueue(app.executor,
      JobRetryPolicy(maxAttempts: 2, delayMs: 0))
    let registry = newDurableJobRegistry()
    var executions: Atomic[int]
    executions.store(0)
    registry.registerHandler("email",
      proc(payload: string) {.gcsafe.} =
        if payload == "fail":
          raise newException(ValueError, "handler failure")
        discard executions.fetchAdd(1))
    expect ValueError:
      registry.registerHandler("email", proc(payload: string) {.gcsafe.} = discard)

    let store = newSqliteDurableJobStore()
    store.enqueue("runner-1", "email", "ok")
    let completed = waitFor registry.runNext(store, queue)
    check completed.processed
    check completed.succeeded
    check executions.load() == 1
    check (waitFor registry.runNext(store, queue)).processed == false

    store.enqueue("runner-2", "email", "fail")
    let failed = waitFor registry.runNext(store, queue)
    check failed.processed
    check not failed.succeeded
    ## A released failed record can be claimed again after the handler is fixed.
    let fixedRegistry = newDurableJobRegistry()
    fixedRegistry.registerHandler("email",
      proc(payload: string) {.gcsafe.} = discard executions.fetchAdd(1))
    let retried = waitFor fixedRegistry.runNext(store, queue)
    check retried.succeeded
    check executions.load() == 2
    store.close()

  test "application jobs CLI recovers and runs configured durable jobs":
    let app = newApplication()
    let store = newSqliteDurableJobStore()
    let registry = newDurableJobRegistry()
    var executions: Atomic[int]
    executions.store(0)
    registry.registerHandler("cli", proc(payload: string) {.gcsafe.} =
      if payload == "expected": discard executions.fetchAdd(1))
    app.configureDurableJobs(store, registry)
    store.enqueue("cli-1", "cli", "expected")
    let claimed = store.claimNext().get()
    check claimed.status == djsProcessing
    check app.runCli(["jobs", "recover"]) == 0
    check app.runCli(["jobs", "run"]) == 0
    check executions.load() == 1
    store.enqueue("cli-2", "cli", "expected")
    check app.runCli(["jobs", "run", "2"]) == 0
    check executions.load() == 2
    check app.runCli(["jobs", "run"]) == 0
    check store.claimNext().isNone
    app.startup()
    app.shutdown()

  test "jobs CLI refuses unconfigured durable execution":
    expect ValueError:
      discard newApplication().runCli(["jobs", "run"])

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

  test "shared rate limit store coordinates application instances":
    let store = newInMemoryRateLimitStore()
    var policy = defaultSecurityPolicy()
    policy.rateLimitRequests = 1
    policy.rateLimitWindowSeconds = 60
    policy.rateLimitStore = store
    policy.rateLimitKey = "shared:application"
    let firstApp = newApplication(defaultConfig(), policy)
    let secondApp = newApplication(defaultConfig(), policy)
    proc health(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("accepted")
    firstApp.get("/shared", "shared-first", health)
    secondApp.get("/shared", "shared-second", health)

    check (waitFor firstApp.dispatch(newRequest("GET", "/shared"))).status == Http200
    let rejected = waitFor secondApp.dispatch(newRequest("GET", "/shared"))
    check rejected.status == Http429
    check rejected.header("Retry-After").isSome

    var unavailablePolicy = policy
    unavailablePolicy.rateLimitStore = RateLimitStore()
    let unavailableApp = newApplication(defaultConfig(), unavailablePolicy)
    unavailableApp.get("/shared", "shared-unavailable", health)
    let unavailable = waitFor unavailableApp.dispatch(newRequest("GET", "/shared"))
    check unavailable.status == Http503
    check unavailable.body == "Rate Limit Store Unavailable"

  test "in-memory rate limit store expires and bounds distinct keys":
    expect ValueError:
      discard newInMemoryRateLimitStore(0)
    let store = newInMemoryRateLimitStore(2)
    check store.consume("a", 1, 60).allowed
    check store.consume("b", 1, 60).allowed
    check store.consume("c", 1, 60).allowed
    ## The oldest active key was evicted, so it starts a fresh window instead
    ## of retaining the previous exhausted counter.
    check store.consume("a", 1, 60).allowed

  test "Redis and Valkey rate limit adapter retries atomically and fails closed":
    let client = FakeRateLimitCounterClient()
    expect ValueError:
      discard newRedisValkeyRateLimitStore(client, maxRetries = -1)
    let store = newRedisValkeyRateLimitStore(client, maxRetries = 1)
    var policy = defaultSecurityPolicy()
    policy.rateLimitRequests = 2
    policy.rateLimitWindowSeconds = 60
    policy.rateLimitStore = store
    policy.rateLimitKey = "remote:application"
    let app = newApplication(defaultConfig(), policy)
    proc remote(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("accepted")
    app.get("/remote", "remote", remote)

    check (waitFor app.dispatch(newRequest("GET", "/remote"))).status == Http200
    check client.calls == 1
    check (waitFor app.dispatch(newRequest("GET", "/remote"))).status == Http200
    let rejected = waitFor app.dispatch(newRequest("GET", "/remote"))
    check rejected.status == Http429
    check rejected.header("Retry-After").get() == "60"

    let flakyClient = FakeRateLimitCounterClient(failuresRemaining: 1)
    let flakyStore = newRedisValkeyRateLimitStore(flakyClient, maxRetries = 1)
    var flakyPolicy = policy
    flakyPolicy.rateLimitStore = flakyStore
    let flakyApp = newApplication(defaultConfig(), flakyPolicy)
    flakyApp.get("/remote", "remote-flaky", remote)
    check (waitFor flakyApp.dispatch(newRequest("GET", "/remote"))).status == Http200
    check flakyClient.calls == 2

    let failedClient = FakeRateLimitCounterClient(failuresRemaining: 3)
    let failedStore = newRedisValkeyRateLimitStore(failedClient, maxRetries = 1)
    var failedPolicy = policy
    failedPolicy.rateLimitStore = failedStore
    let failedApp = newApplication(defaultConfig(), failedPolicy)
    failedApp.get("/remote", "remote-failed", remote)
    check (waitFor failedApp.dispatch(newRequest("GET", "/remote"))).status == Http503
    check failedClient.calls == 2

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

  test "session policy binds a signed subject and protects authenticated routes":
    var policy = defaultSecurityPolicy()
    policy.session.enabled = true
    policy.session.cookieName = "mahanaim_session"
    policy.session.secret = "session-secret-that-is-long-enough-for-checks"
    policy.session.legacySecrets = @[
      "legacy-session-secret-that-is-long-enough"]
    policy.session.requireAuthentication = true
    let app = newApplication(defaultConfig(), policy)
    proc me(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse(request.auth.subject)
    app.get("/me", "current-user", me)

    let anonymous = waitFor app.dispatch(newRequest("GET", "/me"))
    check anonymous.status == Http401
    check anonymous.body == "Authentication Required"

    var authenticated = newRequest("GET", "/me")
    authenticated.cookies[policy.session.cookieName] =
      signValue(policy.session.secret, "user-42")
    let accepted = waitFor app.dispatch(authenticated)
    check accepted.status == Http200
    check accepted.body == "user-42"

    var legacyAuthenticated = newRequest("GET", "/me")
    legacyAuthenticated.cookies[policy.session.cookieName] =
      signValue(policy.session.legacySecrets[0], "legacy-user")
    let rotated = waitFor app.dispatch(legacyAuthenticated)
    let rotatedCookie = rotated.header("Set-Cookie").get()
    let rotatedStart = rotatedCookie.find('=')
    let rotatedEnd = rotatedCookie.find(';')
    let rotatedValue = rotatedCookie[rotatedStart + 1 ..< rotatedEnd]
    check verifySignedValue(policy.session.secret, rotatedValue).get() ==
      "legacy-user"

    var preflight = newRequest("OPTIONS", "/me")
    preflight.headers["origin"] = "https://app.example.com"
    let preflightResponse = waitFor app.dispatch(preflight)
    check preflightResponse.status == Http204

    var invalid = newRequest("GET", "/me")
    invalid.cookies[policy.session.cookieName] = "tampered.value"
    check (waitFor app.dispatch(invalid)).status == Http401

    var loginResponse = textResponse("logged in")
    setSessionCookie(loginResponse, policy.session, "user-42")
    check loginResponse.header("Set-Cookie").get().startsWith(
      "mahanaim_session=")
    var logoutResponse = textResponse("logged out")
    clearSessionCookie(logoutResponse, policy.session)
    check logoutResponse.header("Set-Cookie").get().contains("Max-Age=0")

    var invalidPolicy = defaultSecurityPolicy()
    invalidPolicy.session.enabled = true
    invalidPolicy.session.secret = "short"
    let invalidReport = checkSecurityPolicy(invalidPolicy)
    check not invalidReport.passed
    check invalidReport.issues[0].code == "security.session-secret.weak"

  test "auth backend contract binds a bearer token subject":
    var policy = defaultSecurityPolicy()
    policy.session.requireAuthentication = true
    let backend = newBearerTokenAuthBackend(
      "bearer-secret-that-is-long-enough-for-auth-backend")
    policy.authBackend = backend
    let app = newApplication(defaultConfig(), policy)
    proc bearerMe(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse(request.auth.subject)
    app.get("/bearer-me", "bearer-user", bearerMe)

    check (waitFor app.dispatch(newRequest("GET", "/bearer-me"))).status == Http401
    var authenticated = newRequest("GET", "/bearer-me")
    authenticated.headers["Authorization"] = "Bearer " &
      backend.issueBearerToken("token-user")
    let accepted = waitFor app.dispatch(authenticated)
    check accepted.status == Http200
    check accepted.body == "token-user"

    var wrongScheme = newRequest("GET", "/bearer-me")
    wrongScheme.headers["Authorization"] = "Basic " &
      backend.issueBearerToken("token-user")
    check (waitFor app.dispatch(wrongScheme)).status == Http401

    var tampered = authenticated
    tampered.headers["Authorization"] = "Bearer " &
      authenticated.headers["Authorization"][0 .. ^2] & "0"
    check (waitFor app.dispatch(tampered)).status == Http401

  test "authorization policy composes roles groups object checks and route guards":
    let policy = newAuthorizationPolicy()
    policy.grantPermission("editor", "documents", "read")
    policy.addGroupRole("writers", "editor")
    policy.addSubjectToGroup("user-7", "writers")
    policy.objectPolicy = proc(request: Request, resource, action,
                               objectId: string): bool {.gcsafe.} =
      discard request
      resource == "documents" and action == "read" and objectId == "owned-1"
    let app = newApplication()
    proc document(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse("document:" & request.pathParams["id"])
    app.get("/documents/:id", "document", document,
      @[policy.requirePermission("documents", "read")])

    let anonymous = newRequest("GET", "/documents/owned-1")
    check (waitFor app.dispatch(anonymous)).status == Http403
    var owned = newRequest("GET", "/documents/owned-1")
    owned.auth = AuthContext(authenticated: true, subject: "user-7")
    check (waitFor app.dispatch(owned)).body == "document:owned-1"
    var other = newRequest("GET", "/documents/other")
    other.auth = owned.auth
    check (waitFor app.dispatch(other)).status == Http403

  test "PBKDF2 password hasher uses per-password salt and rejects tampering":
    let hasher = newPbkdf2PasswordHasher(iterations = 10000)
    let first = hasher.hashPassword("correct horse battery staple")
    let second = hasher.hashPassword("correct horse battery staple")
    check first != second
    check hasher.verifyPassword("correct horse battery staple", first)
    check not hasher.passwordNeedsRehash(first)
    let strongerHasher = newPbkdf2PasswordHasher(iterations = 20000)
    check strongerHasher.passwordNeedsRehash(first)
    let upgraded = strongerHasher.verifyAndRehash(
      "correct horse battery staple", first)
    check upgraded.valid
    check upgraded.rehashed
    check strongerHasher.verifyPassword("correct horse battery staple",
      upgraded.encoded)
    let rejectedUpgrade = strongerHasher.verifyAndRehash("wrong password", first)
    check not rejectedUpgrade.valid
    check rejectedUpgrade.encoded == ""
    let changed = hasher.changePassword("correct horse battery staple",
      "new secure password", first)
    check changed.valid
    check hasher.verifyPassword("new secure password", changed.encoded)
    check not hasher.changePassword("wrong password", "another password",
      first).valid
    check not hasher.changePassword("correct horse battery staple",
      "correct horse battery staple", first).valid
    check not hasher.verifyPassword("wrong password", first)
    check not hasher.verifyPassword("correct horse battery staple",
      first[0 .. ^2] & (if first[^1] == '0': "1" else: "0"))
    check not hasher.verifyPassword("correct horse battery staple", "invalid")

  test "Argon2id password hasher emits PHC hashes and rehashes cost changes":
    expect ValueError:
      discard newArgon2idPasswordHasher(memoryKiB = 4096)
    let hasher = newArgon2idPasswordHasher(memoryKiB = 8192,
      iterations = 1, threadCount = 1, derivedBytes = 16)
    let encoded = hasher.hashPassword("correct horse battery staple")
    check encoded.startsWith("$argon2id$")
    check hasher.verifyPassword("correct horse battery staple", encoded)
    check not hasher.verifyPassword("wrong password", encoded)
    check not hasher.passwordNeedsRehash(encoded)
    let stronger = newArgon2idPasswordHasher(memoryKiB = 8192,
      iterations = 2, threadCount = 1, derivedBytes = 16)
    check stronger.passwordNeedsRehash(encoded)
    let upgraded = stronger.verifyAndRehash(
      "correct horse battery staple", encoded)
    check upgraded.valid
    check upgraded.rehashed
    check stronger.verifyPassword("correct horse battery staple", upgraded.encoded)
    check not hasher.verifyPassword("correct horse battery staple", "not-a-phc-hash")

  test "password hasher contract accepts replaceable algorithms":
    let hasher: PasswordHasher = FakePasswordHasher()
    check hasher.hashPassword("secret") == "fake$secret"
    check hasher.verifyPassword("secret", "fake$secret")
    check hasher.passwordNeedsRehash("fake$legacy")
    let changed = hasher.changePassword("secret", "new secret", "fake$secret")
    check changed.valid
    check changed.encoded == "fake$new secret"

  test "password reset tokens are signed and expire":
    let secret = "password-reset-secret-that-is-long-enough"
    let token = issuePasswordResetTokenAt(secret, "user-42", 60, 1000)
    check verifyPasswordResetTokenAt(secret, token, "user-42", 1059)
    check not verifyPasswordResetTokenAt(secret, token, "user-42", 1060)
    check not verifyPasswordResetTokenAt(secret, token, "user-99", 1050)
    check not verifyPasswordResetTokenAt(secret,
      token[0 .. ^2] & (if token[^1] == '0': "1" else: "0"),
      "user-42", 1050)
    expect ValueError:
      discard issuePasswordResetTokenAt("short", "user-42", 60, 1000)

  test "password reset token store consumes each token once":
    let secret = "password-reset-store-secret-that-is-long-enough"
    let token = issuePasswordResetTokenAt(secret, "user-42", 60, 1000)
    let store = newInMemoryPasswordResetTokenStore()
    check store.consumePasswordResetTokenAt(secret, token, "user-42", 1050)
    check not store.consumePasswordResetTokenAt(secret, token, "user-42", 1051)
    let expired = issuePasswordResetTokenAt(secret, "user-42", 10, 1000)
    check not store.consumePasswordResetTokenAt(secret, expired, "user-42", 1010)

  test "login throttle blocks repeated failures and resets on success":
    let throttle = newInMemoryLoginThrottle(maxFailures = 2,
      windowSeconds = 60)
    check throttle.checkAttempt("user-42").allowed
    throttle.recordFailure("user-42")
    check throttle.checkAttempt("user-42").allowed
    throttle.recordFailure("user-42")
    let blocked = throttle.checkAttempt("user-42")
    check not blocked.allowed
    check blocked.retryAfterSeconds >= 1
    throttle.recordSuccess("user-42")
    check throttle.checkAttempt("user-42").allowed

  test "distributed login throttle retries and resets through its counter contract":
    let client = FakeLoginThrottleCounterClient(ttl: 17,
      readFailures: 1, incrementFailures: 1)
    let throttle = newDistributedLoginThrottle(client, maxFailures = 2,
      maxRetries = 1)
    check throttle.checkAttempt("user-42").allowed
    throttle.recordFailure("user-42")
    check client.count == 1
    client.count = 2
    let blocked = throttle.checkAttempt("user-42")
    check not blocked.allowed
    check blocked.retryAfterSeconds == 17
    throttle.recordSuccess("user-42")
    check client.count == 0
    check client.resets == 1
    expect ValueError:
      discard newDistributedLoginThrottle(client, maxRetries = -1)
    expect ValueError:
      discard throttle.checkAttempt("")

  test "account authentication routes compose hashing throttle and session lifecycle":
    var policy = defaultSecurityPolicy()
    policy.session.enabled = true
    policy.session.cookieName = "mahanaim_session"
    policy.session.secret = "account-auth-session-secret-that-is-long-enough"
    policy.session.secureCookie = false
    let accountStore = newInMemoryAccountCredentialStore()
    let accountHasher = newPbkdf2PasswordHasher(iterations = 10000)
    accountStore.addAccount(AccountCredential(
      subject: "user-42", identifier: " user@example.test ",
      passwordHash: accountHasher.hashPassword("correct horse battery staple"),
      enabled: true))
    let rotatingHasher = newPbkdf2PasswordHasher(iterations = 12000)
    let resetStore = newInMemoryPasswordResetTokenStore()
    let resetSecret = "account-reset-secret-that-is-long-enough"
    let authentication = newAccountAuthentication(accountStore, rotatingHasher,
      policy.session, newInMemoryLoginThrottle(maxFailures = 2),
      resetSecret = resetSecret,
      resetTtlSeconds = 60, resetTokenStore = resetStore,
      resetDelivery = discardResetDelivery)
    let app = newTestApplication(securityPolicy = policy)
    app.registerAccountAuthenticationRoutes(authentication)
    let client = newTestClient(app)

    let login = waitFor client.post("/login",
      "{\"identifier\":\"user@example.test\",\"password\":\"correct horse battery staple\"}")
    check login.status == Http200
    check parseJson(login.body)["authenticated"].getBool()
    check parseJson(login.body)["subject"].getStr() == "user-42"
    check login.header("set-cookie").get().startsWith("mahanaim_session=")
    check not accountStore.findBySubject("user-42").get().passwordHash.startsWith(
      "pbkdf2-sha256$10000$")
    check not rotatingHasher.passwordNeedsRehash(
      accountStore.findBySubject("user-42").get().passwordHash)

    let changed = waitFor client.post("/account/password",
      "{\"currentPassword\":\"correct horse battery staple\",\"newPassword\":\"new secure password\"}")
    check changed.status == Http204
    let secondClient = newTestClient(app)
    let oldPassword = waitFor secondClient.post("/login",
      "{\"identifier\":\"user@example.test\",\"password\":\"correct horse battery staple\"}")
    check oldPassword.status == Http401
    let newPassword = waitFor secondClient.post("/login",
      "{\"identifier\":\"user@example.test\",\"password\":\"new secure password\"}")
    check newPassword.status == Http200

    let malformed = waitFor client.post("/login", "{}")
    check malformed.status == Http400
    let wrongOne = waitFor client.post("/login",
      "{\"identifier\":\"user@example.test\",\"password\":\"wrong\"}")
    check wrongOne.status == Http401
    let wrongTwo = waitFor client.post("/login",
      "{\"identifier\":\"user@example.test\",\"password\":\"wrong\"}")
    check wrongTwo.status == Http401
    let blocked = waitFor client.post("/login",
      "{\"identifier\":\"user@example.test\",\"password\":\"wrong\"}")
    check blocked.status == Http429
    check blocked.header("retry-after").isSome

    let logout = waitFor client.post("/logout")
    check logout.status == Http204
    check logout.header("set-cookie").get().contains("Max-Age=0")

    let resetRequested = waitFor client.post("/password-reset",
      "{\"identifier\":\"user@example.test\"}")
    check resetRequested.status == Http202
    check resetRequested.body.len == 0
    let unknownReset = waitFor client.post("/password-reset",
      "{\"identifier\":\"missing@example.test\"}")
    check unknownReset.status == Http202
    let resetToken = issuePasswordResetTokenAt(resetSecret, "user-42", 60,
      getTime().toUnix)
    let resetConfirmed = waitFor client.post("/password-reset/confirm",
      "{\"subject\":\"user-42\",\"token\":\"" & resetToken &
      "\",\"newPassword\":\"reset password\"}")
    check resetConfirmed.status == Http204
    check rotatingHasher.verifyPassword("reset password",
      accountStore.findBySubject("user-42").get().passwordHash)
    let replayedReset = waitFor client.post("/password-reset/confirm",
      "{\"subject\":\"user-42\",\"token\":\"" & resetToken &
      "\",\"newPassword\":\"another password\"}")
    check replayedReset.status == Http400

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
    routeParams["id"] = "Ada Lovelace/?"
    expect ValueError:
      discard app.router.urlFor("typed-user", routeParams)

    var wildcardParams = initTable[string, string]()
    wildcardParams["path"] = "css/site sheet.css"
    check app.router.urlFor("asset-file", wildcardParams) == "/assets/css/site%20sheet.css"
    wildcardParams["path"] = "css//site.css"
    expect ValueError:
      discard app.router.urlFor("asset-file", wildcardParams)

  test "router prefix index preserves static and dynamic precedence":
    let app = newApplication()
    proc staticRoute(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("static")
    proc dynamicRoute(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse("dynamic:" & request.pathParams["id"])
    for index in 0 .. 40:
      app.get("/static-" & $index, "static-" & $index, staticRoute)
    app.get("/:id", "dynamic-id", dynamicRoute)

    let staticResponse = waitFor app.dispatch(newRequest("GET", "/static-40"))
    let dynamicResponse = waitFor app.dispatch(newRequest("GET", "/other"))
    check staticResponse.body == "static"
    check dynamicResponse.body == "dynamic:other"

  test "router tree narrows nested static and parameter candidates":
    let app = newApplication()
    proc selected(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse(request.pathParams.getOrDefault("id", "static"))
    for index in 0 .. 30:
      app.get("/api/v" & $index & "/users/:id", "api-user-" & $index, selected)
    app.get("/api/v30/users/me", "api-user-me", selected)

    let staticResponse = waitFor app.dispatch(newRequest("GET", "/api/v30/users/me"))
    let parameterResponse = waitFor app.dispatch(newRequest("GET", "/api/v30/users/42"))
    check staticResponse.body == "static"
    check parameterResponse.body == "42"

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

  test "locale middleware negotiates Accept-Language into the request":
    let policy = newLocalePolicy(["en", "ko", "ja"], "en", 540)
    check policy.negotiateLocale("ja;q=0.4, ko-KR;q=0.9, en;q=0.8") == "ko"
    check policy.negotiateLocale("fr, *;q=0.5") == "en"
    let app = newApplication()
    app.addMiddleware(localeMiddleware(policy))
    proc localized(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      return textResponse(request.locale & ":" & $request.timezoneOffsetMinutes)
    app.get("/localized", "localized", localized)
    var request = newRequest("GET", "/localized")
    request.headers["accept-language"] = "ja-JP, ko;q=0.8"
    check (waitFor app.dispatch(request)).body == "ja:540"

  test "locale formatter applies explicit timezone and numeric conventions":
    let german = newLocaleFormatPolicy("de-DE", timezoneOffsetMinutes = 540)
    let utcValue = initDateTime(5, mAug, 2026, 15, 30, 0, 0, utc())
    check german.formatDateTime(utcValue) == "2026-08-06 00:30"
    check german.formatDecimal(1234567.5, 2) == "1.234.567,50"

    let english = newLocaleFormatPolicy("en-US", timezoneOffsetMinutes = -300)
    check english.formatDateTime(utcValue) == "8/5/2026 10:30 AM"
    check english.formatDecimal(-1234.5, 1) == "-1,234.5"
    expect ValueError:
      discard newLocaleFormatPolicy("en", timezoneOffsetMinutes = 24 * 60 + 1)
    expect ValueError:
      discard english.formatDecimal(1.0, 13)

  test "IANA locale formatter applies DST-aware offsets":
    let newYork = newIanaLocaleFormatPolicy("en-US", "America/New_York")
    let winter = initDateTime(5, mJan, 2024, 15, 30, 0, 0, utc())
    let summer = initDateTime(5, mJul, 2024, 15, 30, 0, 0, utc())
    check newYork.timezoneName == "America/New_York"
    check newYork.timezoneOffsetMinutes(winter) == -300
    check newYork.timezoneOffsetMinutes(summer) == -240
    check newYork.formatDateTime(winter) == "1/5/2024 10:30 AM"
    check newYork.formatDateTime(summer) == "7/5/2024 11:30 AM"
    expect ValueError:
      discard newIanaLocaleFormatPolicy("en", "Mars/Phobos")

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

  test "observability correlates requests and exposes readiness":
    let app = newApplication()
    proc healthRoute(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("ok")
    app.get("/observed", "observed", healthRoute)
    var request = newRequest("GET", "/observed")
    request.headers["x-request-id"] = "client-42"
    let response = waitFor app.dispatch(request)
    check response.status == Http200
    check response.headers["x-request-id"] == "client-42"
    check app.observability.requestCount == 1
    check app.observability.inFlight == 0
    check readinessResponse(app.observability).status == Http503

    app.startup()
    check readinessResponse(app.observability).status == Http200
    let health = healthResponse(app.observability)
    check health.status == Http200
    check health.body.contains("\"requests\":1")
    app.shutdown()
    check readinessResponse(app.observability).status == Http503

    request.headers["x-request-id"] = "invalid id with spaces"
    let generated = waitFor app.dispatch(request)
    check generated.headers["x-request-id"].startsWith("mahanaim-")

  test "observability exports bounded Prometheus text without vendor coupling":
    let observability = newObservability()
    observability.requestCount = 12
    observability.errorCount = 2
    observability.inFlight = 1
    observability.setReady(true)
    let metrics = prometheusMetrics(observability, "mahanaim")
    check metrics.contains("# TYPE mahanaim_requests_total counter")
    check metrics.contains("mahanaim_requests_total 12")
    check metrics.contains("mahanaim_errors_total 2")
    check metrics.contains("mahanaim_requests_in_flight 1")
    check metrics.contains("mahanaim_ready 1")
    let response = metricsResponse(observability)
    check response.status == Http200
    check response.headers["content-type"] ==
      "text/plain; version=0.0.4; charset=utf-8"
    check response.body.contains("mahanaim_requests_total 12")
    expect ValueError:
      discard prometheusMetrics(observability, "bad metric name")

  test "observability propagates traceparent and emits structured logs":
    var logCount: Atomic[int]
    logCount.store(0)
    let observability = newObservability(logSink = proc(record: JsonNode) {.gcsafe.} =
      discard record
      logCount.store(logCount.load() + 1))
    let app = newApplication()
    app.observability = observability
    app.middlewares[^1] = observabilityMiddleware(observability)
    proc traced(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      check request.trace.traceId.len == 32
      return textResponse("traced")
    app.get("/traced", "traced", traced)
    var request = newRequest("GET", "/traced")
    request.headers["traceparent"] =
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    let response = waitFor app.dispatch(request)
    check response.status == Http200
    check response.headers["traceparent"] == request.headers["traceparent"]
    check logCount.load() == 1
    let record = requestEventJson(RequestEvent(requestId: "request-1",
      httpMethod: "GET", path: "/traced", status: 200,
      traceId: "4bf92f3577b34da6a3ce929d0e0e4736", spanId: "00f067aa0ba902b7"))
    check record["event"].getStr() == "http.request"
    check record["traceId"].getStr() == "4bf92f3577b34da6a3ce929d0e0e4736"
    check parseTraceParent("00-00000000000000000000000000000000-00f067aa0ba902b7-01").isNone

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

  test "release checks validate runtime matrix and artifact checksums":
    let artifactPath = getTempDir() / "mahanaim-release-check.txt"
    writeFile(artifactPath, "artifact bytes")
    defer:
      if fileExists(artifactPath): removeFile(artifactPath)
    let checksum = sha256File(artifactPath)
    check checksum.len == 64
    check verifyArtifactChecksum(ReleaseArtifact(path: artifactPath,
      sha256: checksum))
    check not verifyArtifactChecksum(ReleaseArtifact(path: artifactPath,
      sha256: checksum[0 ..< 63] & "0"))
    check validateReleaseArtifacts(@[
      ReleaseArtifact(path: artifactPath, sha256: checksum)]).len == 0
    check validateReleaseArtifacts(@[
      ReleaseArtifact(path: artifactPath, sha256: "invalid")]).len == 1
    let matrix = RuntimeSupportMatrix(minimumNim: currentNimVersion(),
      operatingSystems: @[currentOperatingSystem()])
    check validateRuntimeSupport(matrix).len == 0
    check validateRuntimeSupport(RuntimeSupportMatrix(
      minimumNim: NimVersionSpec(major: 999, minor: 0, patch: 0),
      operatingSystems: @[currentOperatingSystem()])).len > 0

  test "network adapter serves an application over HTTP":
    let app = newApplication()
    proc hello(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("hello over http")
    app.get("/hello", "hello", hello)
    proc variants(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return responseVariants([
        textResponse("buffered variant"),
        sseResponse([SseEvent(event: "message", data: "stream variant",
          retryMs: -1)])])
    app.get("/variants", "variants", variants)
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
    var acceptHeaders = newHttpHeaders()
    acceptHeaders["Accept"] = "application/json"
    let rejected = waitFor client.request(
      "http://127.0.0.1:" & $network.boundPort().uint16 & "/hello",
      HttpGet, headers = acceptHeaders)
    check rejected.code == Http406
    discard waitFor rejected.body()
    var streamHeaders = newHttpHeaders()
    streamHeaders["Accept"] = "text/event-stream"
    let selected = waitFor client.request(
      "http://127.0.0.1:" & $network.boundPort().uint16 & "/variants",
      HttpGet, headers = streamHeaders)
    check selected.code == Http200
    check selected.headers["transfer-encoding"] == "chunked"
    check (waitFor selected.body()) == "event: message\ndata: stream variant\n\n"
    client.close()
    network.close()
    network.close()

  test "network adapter serves SSE representation framing over TCP":
    let app = newApplication()
    proc events(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return sseResponse([SseEvent(event: "tick", id: "1", retryMs: 500,
        data: "hello")])
    app.get("/events", "events", events)
    let network = newNetworkServer(app, "127.0.0.1", 0)
    asyncCheck network.serve()
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
    let wireResponse = waitFor client.get(
      "http://127.0.0.1:" & $network.boundPort().uint16 & "/events")
    let body = waitFor wireResponse.body()
    check wireResponse.code == Http200
    check wireResponse.headers["content-type"] == "text/event-stream; charset=utf-8"
    check body == "event: tick\nid: 1\nretry: 500\ndata: hello\n\n"
    client.close()
    network.close()

  test "network adapter writes stream responses with chunked transfer framing":
    var app = newApplication()
    let expectedBody = "chunk-".repeat(2000)
    app.get("/stream", "stream", proc(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      streamResponse("chunk-".repeat(2000), "text/plain"))
    let network = newNetworkServer(app, "127.0.0.1", 0)
    asyncCheck network.serve()
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
    let response = waitFor client.get(
      "http://127.0.0.1:" & $network.boundPort().uint16 & "/stream")
    check response.headers.getOrDefault("transfer-encoding") == "chunked"
    check response.headers.getOrDefault("content-length") == ""
    let body = waitFor response.body()
    check body == expectedBody
    client.close()
    network.close()

  test "network adapter upgrades a WebSocket and exchanges masked text frames":
    let app = newApplication()
    app.websocket("/echo", "echoSocket",
      proc(request: Request, session: WebSocketSession): Future[void] {.async, gcsafe.} =
        discard request
        let incoming = await session.receive()
        await session.send(incoming))
    let network = newNetworkServer(app, "127.0.0.1", 0)
    asyncCheck network.serve()
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

    let client = newAsyncSocket()
    waitFor client.connect("127.0.0.1", network.boundPort())
    let key = "dGhlIHNhbXBsZSBub25jZQ=="
    waitFor client.send("GET /echo HTTP/1.1\r\n" &
      "Host: 127.0.0.1\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: Upgrade\r\n" &
      "Accept: application/json\r\n" &
      "Sec-WebSocket-Version: 13\r\n" &
      "Sec-WebSocket-Key: " & key & "\r\n\r\n")
    var handshake = ""
    while not handshake.endsWith("\r\n\r\n"):
      handshake.add(waitFor client.recv(1))
    check handshake.contains("101 Switching Protocols")
    check handshake.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    let clearText = "hello"
    let mask = [byte(1), byte(2), byte(3), byte(4)]
    var frame = "\x81" & char(0x80 or clearText.len)
    for value in mask:
      frame.add(char(value))
    for index, value in clearText:
      frame.add(char(ord(value) xor int(mask[index mod 4])))
    waitFor client.send(frame)
    let responseHeader = waitFor client.recv(2)
    check (ord(responseHeader[0]) and 0x0f) == 0x1
    let echoed = waitFor client.recv(ord(responseHeader[1]) and 0x7f)
    check echoed == clearText
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

  test "Prologue form body crosses the adapter into the common parser":
    var nativeHeaders = newHttpHeaders()
    nativeHeaders["Content-Type"] = "application/x-www-form-urlencoded"
    var nativeRequest = request.initMockingRequest(
      HttpPost, nativeHeaders, parseUri("/submit"))
    # Prologue's mocking constructor has no body parameter, so populate its
    # native snapshot exactly as the network backend would have done.
    nativeRequest.nativeRequest.body = "name=Ada&role=admin"

    let frameworkRequest = toFrameworkRequest(nativeRequest)
    let parsed = parseRequestBody(frameworkRequest)
    check parsed.valid
    check parsed.encoding == beFormUrlEncoded
    check parsed.fields["name"] == "Ada"
    check parsed.fields["role"] == "admin"

  test "Prologue multipart upload crosses the adapter into safe storage":
    var nativeHeaders = newHttpHeaders()
    nativeHeaders["Content-Type"] = "multipart/form-data; boundary=demo"
    var nativeRequest = request.initMockingRequest(
      HttpPost, nativeHeaders, parseUri("/upload"))
    nativeRequest.nativeRequest.body =
      "--demo\r\n" &
      "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" &
      "Content-Type: text/plain\r\n\r\n" &
      "hello\r\n" &
      "--demo--\r\n"
    let root = getTempDir() / "mahanaim_prologue_upload_test"
    if dirExists(root):
      removeDir(root)
    let stored = savePrologueUpload(nativeRequest, "file",
      newUploadPolicy(root, allowedContentTypes = @["text/plain"]))
    check stored.originalFilename == "a.txt"
    check readFile(stored.path) == "hello"
    removeDir(root)

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

  when defined(windows):
    test "Prologue adapter owns a live socket and closes it gracefully":
      ## The Windows Prologue backend uses stdlib AsyncHttpServer request
      ## values. This fixture proves Mahanaim owns the transport boundary,
      ## can select an ephemeral port, and can interrupt its accept loop.
      let app = newApplication()
      proc hello(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
        discard request
        return textResponse("hello from live prologue")
      app.get("/live", "live-hello", hello)
      proc variants(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
        discard request
        return responseVariants([
          textResponse("prologue text"), jsonResponse("{\"backend\":\"prologue\"}")])
      app.get("/variants", "live-variants", variants)
      app.websocket("/socket", "live-socket",
        proc(request: Request, session: WebSocketSession): Future[void] {.async, gcsafe.} =
          discard request
          await session.send(await session.receive()))
      let settings = prologueSettings.newSettings(
        address = "127.0.0.1", port = Port(0), debug = false)
      let adapter = newPrologueServer(app, settings)
      asyncCheck adapter.runAsync()

      var attempts = 0
      while attempts < 50:
        try:
          if adapter.boundPort().uint16 > 0:
            break
        except OSError:
          discard
        waitFor sleepAsync(10)
        inc attempts
      check adapter.boundPort().uint16 > 0

      let client = hc.newAsyncHttpClient()
      let response = waitFor client.getContent(
        "http://127.0.0.1:" & $adapter.boundPort().uint16 & "/live")
      check response == "hello from live prologue"
      var acceptHeaders = newHttpHeaders()
      acceptHeaders["Accept"] = "application/json"
      let variantResponse = waitFor client.request(
        "http://127.0.0.1:" & $adapter.boundPort().uint16 & "/variants",
        HttpGet, headers = acceptHeaders)
      check variantResponse.code == Http200
      check variantResponse.headers["content-type"].startsWith("application/json")
      check (waitFor variantResponse.body()) == "{\"backend\":\"prologue\"}"
      client.close()

      ## A regular HTTP Accept header must not prevent a protocol upgrade.
      ## This also exercises the Prologue bridge's handled flag after the
      ## adapter takes ownership of the connection.
      let socket = newAsyncSocket()
      waitFor socket.connect("127.0.0.1", adapter.boundPort())
      let key = "dGhlIHNhbXBsZSBub25jZQ=="
      waitFor socket.send("GET /socket HTTP/1.1\r\n" &
        "Host: 127.0.0.1\r\n" &
        "Upgrade: websocket\r\n" &
        "Connection: Upgrade\r\n" &
        "Accept: application/json\r\n" &
        "Sec-WebSocket-Version: 13\r\n" &
        "Sec-WebSocket-Key: " & key & "\r\n\r\n")
      var handshake = ""
      while not handshake.endsWith("\r\n\r\n"):
        handshake.add(waitFor socket.recv(1))
      check handshake.contains("101 Switching Protocols")
      check handshake.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
      let clearText = "prologue"
      let mask = [byte(1), byte(2), byte(3), byte(4)]
      var frame = "\x81" & char(0x80 or clearText.len)
      for value in mask:
        frame.add(char(value))
      for index, value in clearText:
        frame.add(char(ord(value) xor int(mask[index mod 4])))
      waitFor socket.send(frame)
      let responseHeader = waitFor socket.recv(2)
      check (ord(responseHeader[0]) and 0x0f) == 0x1
      let echoed = waitFor socket.recv(ord(responseHeader[1]) and 0x7f)
      check echoed == clearText
      socket.close()

      adapter.close()
      adapter.close()
      check adapter.closed

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

  test "test client parses SSE events and drives in-process WebSocket sessions":
    let app = newTestApplication()
    app.get("/events", "test-events",
      proc(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
        return sseResponse([
          SseEvent(event: "message", id: "one", retryMs: 1000,
            data: "first\nline"),
          SseEvent(event: "done", id: "two", retryMs: -1, data: "last")]))
    app.websocket("/rooms/:room", "test-room",
      proc(request: Request, session: WebSocketSession): Future[void] {.async, gcsafe.} =
        let incoming = await session.receive()
        await session.send(textWebSocketMessage(
          request.pathParams.getOrDefault("room") & ":" & incoming.payload))
        await session.close(1000, "done"))

    let client = newTestClient(app)
    let events = waitFor client.getSseEvents("/events")
    check events.len == 2
    check events[0].event == "message"
    check events[0].id == "one"
    check events[0].retryMs == 1000
    check events[0].data == "first\nline"
    check events[1].event == "done"
    check events[1].retryMs == -1

    let socket = client.connectWebSocket("/rooms/42")
    waitFor socket.send(textWebSocketMessage("hello"))
    let echoed = waitFor socket.receive()
    check echoed.kind == wsmText
    check echoed.payload == "42:hello"
    let closed = waitFor socket.receive()
    check closed.kind == wsmClose
    check closed.closeCode == 1000
    check closed.payload == "done"
    waitFor socket.wait()
    check socket.closed

  test "network test fixture owns real adapter readiness and shutdown":
    let app = newTestApplication()
    app.get("/fixture", "fixture",
      proc(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
        return textResponse("fixture-ready"))
    let fixture = newNetworkTestFixture(app)
    asyncCheck fixture.start()
    let port = waitFor fixture.waitUntilReady()
    let client = hc.newAsyncHttpClient()
    try:
      let response = waitFor client.get(
        "http://127.0.0.1:" & $port.uint16 & "/fixture")
      check response.code == Http200
      check (waitFor response.body()) == "fixture-ready"
    finally:
      client.close()
      fixture.close()
      fixture.close()

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
    check fileExists(root / ".env.example")
    check fileExists(root / ".gitignore")
    check fileExists(root / "src" / "sample_app.nim")
    check fileExists(root / "tests" / "test_app.nim")
    check readFile(root / ".env.example").contains("MAHANAIM_PORT=8000")
    check readFile(root / "src" / "sample_app.nim").contains("proc createApp*")
    check readFile(root / "tests" / "test_app.nim").contains("/health")
    let (dependencyOutput, dependencyExitCode) = execCmdEx(
      "nimble path nimcrypto parsetoml prologue taskpools db_connector " &
      "argon2 timezones cookiejar httpx ioselectors wepoll logue cligen regex unicodedb")
    check dependencyExitCode == 0
    var dependencyArgs = ""
    for path in dependencyOutput.splitLines:
      let normalized = path.strip()
      if normalized.len > 0:
        dependencyArgs.add(" --path:" & quoteShell(normalized))
    let compileCommand = "nim c --path:src" & dependencyArgs & " --path:" &
      quoteShell(root / "src") & " -r " & quoteShell(root / "tests" / "test_app.nim")
    let (compileOutput, compileExitCode) = execCmdEx(compileCommand)
    if compileExitCode != 0:
      echo compileOutput
    check compileExitCode == 0
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

  test "form binding reuses validation and escapes rendered values":
    var request = newRequest("POST", "/profile", "name=%3Cscript%3E&age=bad")
    request.headers["content-type"] = "application/x-www-form-urlencoded"
    let form = bindForm(request, [
      stringField("name", flBody),
      integerField("age", flBody)])
    check form.errors.len == 1
    check form.fields[0].value == "<script>"
    var policy = defaultSecurityPolicy()
    policy.csrfEnabled = true
    policy.csrfSecret = "01234567890123456789012345678901"
    let html = renderForm(form, "/profile", "POST", policy)
    check html.contains("&lt;script&gt;")
    check html.contains("name=\"x-csrf-token\"")
    check html.contains("class=\"form-error\"")

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

  test "upload storage validates and saves multipart files safely":
    let root = getTempDir() / "mahanaim_upload_test"
    if dirExists(root):
      removeDir(root)
    let part = BodyPart(name: "avatar", filename: "avatar.txt",
      contentType: "text/plain", content: "hello")
    let policy = newUploadPolicy(root, maxBytes = 10,
      allowedContentTypes = @["text/plain"])
    let stored = saveUpload(part, policy)
    check stored.originalFilename == "avatar.txt"
    check stored.size == 5
    check readFile(stored.path) == "hello"

    expect UploadValidationError:
      discard saveUpload(BodyPart(name: "file", filename: "../escape.txt",
        contentType: "text/plain", content: "x"), policy)
    expect UploadValidationError:
      discard saveUpload(part, policy)
    expect UploadValidationError:
      discard saveUpload(BodyPart(name: "file", filename: "image.bin",
        contentType: "application/octet-stream", content: "x"), policy)
    expect UploadValidationError:
      discard saveUpload(BodyPart(name: "file", filename: "large.txt",
        contentType: "text/plain", content: "01234567890"), policy)
    let constrained = newUploadPolicy(root, allowedExtensions = @["txt"],
      webRootDirectory = getTempDir() / "mahanaim_public")
    expect UploadValidationError:
      discard saveUpload(BodyPart(name: "file", filename: "payload.bin",
        contentType: "text/plain", content: "x"), constrained)
    expect UploadValidationError:
      discard newUploadPolicy(root,
        webRootDirectory = root / "public")
    removeDir(root)

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
    check selectedJson.header("Vary").get() == "Accept"

    request.headers["accept"] = "text/html"
    let selectedHtml = negotiateResponse(request, [
      htmlResponse("<p>hello</p>"), jsonResponse("{\"message\":\"hello\"}")
    ])
    check selectedHtml.header("Content-Type").get() == "text/html; charset=utf-8"

    request.headers["accept"] = "image/png"
    let unavailable = negotiateResponse(request, [htmlResponse("<p>hello</p>")])
    check unavailable.status == Http406
    check unavailable.header("Vary").get() == "Accept"
    let single = negotiateResponse(request, textResponse("hello"))
    check single.status == Http406
    check single.header("Vary").get() == "Accept"
    request.headers["accept"] = "text/plain"
    check negotiateResponse(request, textResponse("hello")).status == Http200
    let candidates = responseVariants([
      textResponse("plain"), jsonResponse("{\"ok\":true}")])
    request.headers["accept"] = "application/json"
    let selected = negotiateResponse(request, candidates)
    check selected.body == "{\"ok\":true}"
    check selected.variants.len == 0
    request.headers["accept"] = "image/png"
    check negotiateResponse(request, candidates).status == Http406

  test "response policy negotiates streaming representations with cache variance":
    var request = newRequest("GET", "/streaming")
    request.headers["accept"] = "text/event-stream"
    let sse = negotiateResponse(request, [
      streamResponse("chunk", "text/plain"),
      sseResponse([SseEvent(event: "message", data: "hello")]),
      webSocketResponse()
    ])
    check sse.representation == rrServerSentEvents
    check sse.header("Vary").get() == "Accept"

    request.headers["accept"] = "application/websocket"
    let websocket = negotiateResponse(request, [
      streamResponse("chunk", "text/plain"), webSocketResponse()])
    check websocket.representation == rrWebSocket

    request.headers["accept"] = "text/plain"
    let stream = negotiateResponse(request, [
      streamResponse("chunk", "text/plain"), sseResponse(@[])])
    check stream.representation == rrStream

  test "response negotiation honors Accept quality and q zero":
    var request = newRequest("GET", "/quality")
    request.headers["accept"] = "text/plain;q=0.2, application/json;q=0.9"
    let selected = negotiateResponse(request, [
      textResponse("text"), jsonResponse("{\"ok\":true}")])
    check selected.headers["content-type"].startsWith("application/json")
    request.headers["accept"] = "application/json;q=0"
    check negotiateResponse(request, jsonResponse("{\"ok\":true}")).status == Http406

  test "HTML JSON response helper selects HTMX partials and JSON":
    var request = newRequest("GET", "/items")
    let full = htmlJsonResponse(request, "<main>full</main>",
      "<li>partial</li>", "{\"items\":[]}")
    check full.body == "<main>full</main>"
    check full.header("Vary").get() == "Accept, HX-Request"

    request.headers["HX-Request"] = "true"
    let partial = htmlJsonResponse(request, "<main>full</main>",
      "<li>partial</li>", "{\"items\":[]}")
    check partial.body == "<li>partial</li>"
    check isHtmxRequest(request)

    request.headers["accept"] = "application/json"
    let json = htmlJsonResponse(request, "<main>full</main>",
      "<li>partial</li>", "{\"items\":[]}")
    check json.header("Content-Type").get().startsWith("application/json")
    check json.body == "{\"items\":[]}"

    request.headers["accept"] = "image/png"
    check htmlJsonResponse(request, "full", "partial", "{}").status == Http406

  test "stream and SSE responses expose representation metadata":
    let stream = streamResponse("chunk", "text/plain")
    check stream.representation == rrStream
    check stream.header("Content-Type").get() == "text/plain"

    let sse = sseResponse([
      SseEvent(event: "message", id: "42", retryMs: 1000,
        data: "first\nsecond")])
    check sse.representation == rrServerSentEvents
    check sse.header("Content-Type").get() == "text/event-stream; charset=utf-8"
    check sse.body == "event: message\nid: 42\nretry: 1000\ndata: first\ndata: second\n\n"

    let websocket = webSocketResponse()
    check websocket.representation == rrWebSocket
    check websocket.status == Http101

  test "WebSocket core contract preserves frame kinds and adapter boundary":
    let textFrame = textWebSocketMessage("hello")
    check textFrame.kind == wsmText
    check textFrame.payload == "hello"
    let binaryFrame = binaryWebSocketMessage("bytes")
    check binaryFrame.kind == wsmBinary
    let pingFrame = controlWebSocketMessage(wsmPing, "probe")
    check pingFrame.kind == wsmPing
    let closeFrame = closeWebSocketMessage(1001, "going away")
    check closeFrame.kind == wsmClose
    check closeFrame.closeCode == 1001
    check closeFrame.payload == "going away"
    expect ValueError:
      discard controlWebSocketMessage(wsmText)
    expect ValueError:
      discard newWebSocketSession().send(textFrame)

  test "WebSocket routes use a separate registry and preserve path precedence":
    var app = newApplication()
    app.websocket("/rooms/:id", "roomSocket",
      proc(request: Request, session: WebSocketSession): Future[void] {.async, gcsafe.} =
        discard request
        discard session
        discard)
    app.websocket("/rooms/*path", "roomWildcard",
      proc(request: Request, session: WebSocketSession): Future[void] {.async, gcsafe.} =
        discard request
        discard session)
    let matched = app.router.findWebSocket("/rooms/42")
    check matched.isSome
    check matched.get().name == "roomSocket"
    check app.router.routes.len == 0

  test "response cookie helper applies safe defaults":
    var response = textResponse("ok")
    response.setCookie("session", "a;b", secure = true, maxAge = 3600)
    let cookie = response.header("Set-Cookie").get()
    check cookie.contains("session=a%3Bb")
    check cookie.contains("Path=/")
    check cookie.contains("HttpOnly")
    check cookie.contains("Secure")
    check cookie.contains("Max-Age=3600")

  test "signed cookie keyrings accept legacy keys and expose rotation":
    let primary = "primary-cookie-key-that-is-long-enough"
    let legacy = "legacy-cookie-key-that-is-long-enough"
    let signedWithLegacy = signValue(legacy, "user.42")
    let verification = verifySignedValueWithKeyring(
      @[primary, legacy], signedWithLegacy).get()
    check verification.value == "user.42"
    check verification.keyIndex == 1
    check verification.needsRotation

    var response = textResponse("ok")
    response.setRotatedSignedCookie("session", primary, verification)
    check response.header("Set-Cookie").get().contains(
      signValue(primary, "user.42"))

    check verifySignedValueWithKeyring(@[primary], signedWithLegacy).isNone

  test "configuration merges dotenv JSON TOML and environment values":
    let root = getTempDir() / "mahanaim_config_test"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    let dotenvPath = root / ".env"
    let jsonPath = root / "config.json"
    let tomlPath = root / "config.toml"
    writeFile(dotenvPath, "MAHANAIM_HOST=dotenv-host\nSECRET_TOKEN=dotenv-secret\n")
    writeFile(jsonPath, "{\"port\":9000,\"request_timeout_ms\":25," &
      "\"ports\":[8000,8001],\"features\":{\"beta\":true}," &
      "\"secrets\":{\"token\":\"json-secret\"}}")
    writeFile(tomlPath, "environment = \"staging\" # deployment profile\n" &
      "port = 9200\nrelease_date = 2026-08-04\n" &
      "[database]\npool_size = 4\n[secrets]\ntoken = \"toml-secret\"\n")
    putEnv("MAHANAIM_PORT", "9100")
    putEnv("MAHANAIM_REQUEST_TIMEOUT_MS", "35")
    putEnv("MAHANAIM_EXECUTOR_MAX_CONCURRENT_JOBS", "3")
    let config = loadConfig(dotenvPath, jsonPath, tomlPath)
    check config.host == "dotenv-host"
    check config.environment == "staging"
    check config.port == 9100
    check config.requestTimeoutMs == 35
    check config.executorMaxConcurrentJobs == 3
    check config.secrets["token"] == "toml-secret"
    check config.values["ports"].kind == JArray
    check config.values["ports"][0].getInt() == 8000
    check config.values["features"]["beta"].getBool()
    check config.values["release_date"].getStr() == "2026-08-04"
    check config.values["database"]["pool_size"].getInt() == 4
    check redactSecrets("token=toml-secret", config) == "token=[REDACTED]"

  test "TOML schema rejects unsupported and unknown values":
    let root = getTempDir() / "mahanaim_toml_schema_test"
    createDir(root)
    let arrayPath = root / "array.toml"
    let unknownPath = root / "unknown.toml"
    writeFile(arrayPath, "ports = [8000, 8001]\n")
    writeFile(unknownPath, "feature_flag = true\n")
    expect ValueError:
      discard loadTomlConfig(arrayPath)
    expect ValueError:
      discard loadTomlConfig(unknownPath)
    delEnv("MAHANAIM_PORT")
    delEnv("MAHANAIM_REQUEST_TIMEOUT_MS")
    delEnv("MAHANAIM_EXECUTOR_MAX_CONCURRENT_JOBS")
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

    var patchValues = initTable[string, JsonNode]()
    patchValues["display_name"] = parseJson("\"Grace\"")
    let patch = serializePatch(account, patchValues)
    check patch.valid
    check patch.document["displayName"].getStr() == "Grace"
    check patch.document.hasKey("id") == false

    let projection = serializeProjection(account, values,
      ["display_name", "email"])
    check projection.valid
    check projection.document.hasKey("displayName")
    check projection.document.hasKey("email")
    check projection.document.hasKey("id") == false
    let invalidProjection = serializeProjection(account, values, ["missing"])
    check not invalidProjection.valid
    check invalidProjection.errors[0].code == "unknown_projection"

  test "metadata serializer enforces string-backed enum values":
    var ticket = newModelMetadata("Ticket")
    ticket.addField(newEnumModelField("state", ["open", "closed"]))
    var values = initTable[string, JsonNode]()
    values["state"] = newJString("open")
    check serializeModel(ticket, values).valid
    values["state"] = newJString("pending")
    let invalid = serializeModel(ticket, values)
    check not invalid.valid
    check invalid.errors[0].code == "invalid_enum"
    expect ValueError:
      discard newEnumModelField("empty", [])

  test "model enum metadata reaches validation and OpenAPI":
    var metadata = newModelMetadata("Ticket")
    metadata.addField(newEnumModelField("state", ["open", "closed"]))
    let schema = modelInputSchema(metadata)
    check schema[0].enumValues == @["open", "closed"]
    var invalidRequest = newRequest("POST", "/tickets", "{\"state\":\"pending\"}")
    let validation = validate(invalidRequest, schema)
    check not validation.valid
    check validation.errors[0].code == "invalid_enum"
    let document = modelOpenApiDocument("Tickets", "1.0.0", metadata)
    let stateSchema = document["paths"]["/generated"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"]["state"]
    check stateSchema["enum"][0].getStr() == "open"

    var profile = newModelMetadata("Profile", "profiles")
    profile.addField(newModelField("display_name", modelString,
      jsonName = "displayName"))
    var user = newModelMetadata("UserDto", "users")
    user.addField(newModelField("id", modelInteger, primaryKey = true))
    user.addField(newModelField("profile", modelJson, nestedModel = "Profile"))
    var registry = initModelRegistry()
    registry.registerModel(profile)
    registry.registerModel(user)
    var graphValues = initTable[string, JsonNode]()
    graphValues["id"] = parseJson("7")
    graphValues["profile"] = parseJson("{\"displayName\":\"Ada\"}")
    let graph = serializeModelGraph(user, graphValues, registry)
    check graph.valid
    check graph.document["profile"]["displayName"].getStr() == "Ada"

    let graphDocument = modelOpenApiDocument("Users", "1.0.0", user, registry)
    let profileProperty = graphDocument["components"]["schemas"]["UserDto"][
      "properties"]["profile"]
    check profileProperty["$ref"].getStr() == "#/components/schemas/Profile"
    check graphDocument["components"]["schemas"]["Profile"]["properties"][
      "displayName"]["type"].getStr() == "string"

    var cycle = newModelMetadata("Cycle", "cycles")
    cycle.addField(newModelField("child", modelJson, nestedModel = "Cycle"))
    registry.registerModel(cycle)
    let cycleDocument = modelOpenApiDocument("Cycles", "1.0.0", cycle, registry)
    check cycleDocument["components"]["schemas"]["Cycle"]["properties"][
      "child"]["$ref"].getStr() == "#/components/schemas/Cycle"
    var missing = newModelMetadata("MissingRoot")
    missing.addField(newModelField("child", modelJson, nestedModel = "Unknown"))
    registry.registerModel(missing)
    expect ValueError:
      discard modelOpenApiDocument("Missing", "1.0.0", missing, registry)

  test "standard serializer adapter canonicalizes date UUID and file metadata":
    var asset = newModelMetadata("Asset", "assets")
    asset.addField(newModelField("created_at", modelDateTime,
      jsonName = "createdAt"))
    asset.addField(newModelField("owner_id", modelUuid,
      jsonName = "ownerId"))
    asset.addField(newModelField("file", modelFile))
    var values = initTable[string, JsonNode]()
    values["created_at"] = parseJson("\"2026-08-04T09:30:00Z\"")
    values["owner_id"] = parseJson("\"550E8400-E29B-41D4-A716-446655440000\"")
    values["file"] = parseJson("{\"name\":\"report.pdf\",\"contentType\":\"application/pdf\",\"size\":42}")

    let serialized = serializeModel(asset, values,
      adapter = newStandardSerializationAdapter())
    check serialized.valid
    check serialized.document["createdAt"].getStr() == "2026-08-04T09:30:00Z"
    check serialized.document["ownerId"].getStr() == "550e8400-e29b-41d4-a716-446655440000"
    check serialized.document["file"]["size"].getInt() == 42

    values["owner_id"] = parseJson("\"not-a-uuid\"")
    let invalid = serializeModel(asset, values,
      adapter = newStandardSerializationAdapter())
    check not invalid.valid
    check invalid.errors[0].code == "adapter_error"

  test "metadata CRUD resource convention works with an adapter store":
    var metadata = newModelMetadata("Item", "items")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("title", modelString))
    let store = newInMemoryResourceStore(metadata)
    let resource = newCrudResource(metadata, store)
    let app = newApplication()
    registerCrudRoutes(app, resource, "/items", "items")

    let created = waitFor app.dispatch(newRequest("POST", "/items",
      "{\"title\":\"first\"}"))
    check created.status == Http201
    let createdDocument = parseJson(created.body)
    let id = createdDocument["id"].getInt()
    check createdDocument["title"].getStr() == "first"

    let listed = waitFor app.dispatch(newRequest("GET", "/items"))
    check listed.status == Http200
    check parseJson(listed.body).len == 1
    let updated = waitFor app.dispatch(newRequest("PUT", "/items/" & $id,
      "{\"title\":\"updated\"}"))
    check updated.status == Http200
    check parseJson(updated.body)["title"].getStr() == "updated"
    let deleted = waitFor app.dispatch(newRequest("DELETE", "/items/" & $id))
    check deleted.status == Http204
    check (waitFor app.dispatch(newRequest("GET", "/items/" & $id))).status == Http404
    check (waitFor app.dispatch(newRequest("POST", "/items", "not-json"))).status == Http400
    check (waitFor app.dispatch(newRequest("POST", "/items", "{}"))).status == Http400
    check (waitFor app.dispatch(newRequest("POST", "/items",
      "{\"title\":\"ok\",\"unknown\":true}"))).status == Http400

  test "CRUD list route executes shared query filtering ordering pagination and projection":
    var metadata = newModelMetadata("RankedItem", "ranked_items")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("name", modelString))
    metadata.addField(newModelField("active", modelBoolean))
    metadata.addField(newModelField("score", modelInteger))
    let app = newApplication()
    let resource = newCrudResource(metadata, newInMemoryResourceStore(metadata))
    registerCrudRoutes(app, resource, "/ranked-items", "ranked-items")
    discard waitFor app.dispatch(newRequest("POST", "/ranked-items",
      "{\"name\":\"low\",\"active\":true,\"score\":1}"))
    discard waitFor app.dispatch(newRequest("POST", "/ranked-items",
      "{\"name\":\"high\",\"active\":true,\"score\":3}"))
    discard waitFor app.dispatch(newRequest("POST", "/ranked-items",
      "{\"name\":\"inactive\",\"active\":false,\"score\":9}"))

    var request = newRequest("GET", "/ranked-items")
    request.query["filter.active"] = "true"
    request.query["filter.name__like"] = "h%"
    request.query["sort"] = "-score"
    request.query["page_size"] = "1"
    request.query["fields"] = "name,score"
    let listed = waitFor app.dispatch(request)
    check listed.status == Http200
    let document = parseJson(listed.body)
    check document.len == 1
    check document[0]["name"].getStr() == "high"
    check document[0]["score"].getInt() == 3
    check not document[0].hasKey("active")

    var totalRequest = newRequest("GET", "/ranked-items")
    totalRequest.query["filter.active"] = "true"
    totalRequest.query["page_size"] = "1"
    totalRequest.query["include_total"] = "true"
    let withTotal = waitFor app.dispatch(totalRequest)
    check withTotal.status == Http200
    let totalDocument = parseJson(withTotal.body)
    check totalDocument["items"].len == 1
    check totalDocument["total"].getInt() == 2

    var cursorRequest = newRequest("GET", "/ranked-items")
    cursorRequest.query["cursor"] = encodeCursor(integerValue(1))
    cursorRequest.query["sort"] = "id"
    cursorRequest.query["page_size"] = "1"
    let cursorPage = waitFor app.dispatch(cursorRequest)
    check cursorPage.status == Http200
    let cursorDocument = parseJson(cursorPage.body)
    check cursorDocument["items"].len == 1
    check cursorDocument["items"][0]["name"].getStr() == "high"
    check cursorDocument["next_cursor"].kind == JString
    check decodeCursor(cursorDocument["next_cursor"].getStr()).get().integer == 2

    var lastCursorRequest = newRequest("GET", "/ranked-items")
    lastCursorRequest.query["cursor"] = cursorDocument["next_cursor"].getStr()
    lastCursorRequest.query["sort"] = "id"
    lastCursorRequest.query["page_size"] = "1"
    let lastCursorPage = waitFor app.dispatch(lastCursorRequest)
    let lastCursorDocument = parseJson(lastCursorPage.body)
    check lastCursorDocument["items"][0]["name"].getStr() == "inactive"
    check lastCursorDocument["next_cursor"].kind == JNull

    let cursorSecret = "cursor-secret-that-is-long-enough-for-tests"
    resource.cursorSecret = cursorSecret
    resource.cursorTtlSeconds = 60
    let signedCursor = encodeCursor(integerValue(1), cursorSecret, 60)
    var signedRequest = newRequest("GET", "/ranked-items")
    signedRequest.query["cursor"] = signedCursor
    signedRequest.query["sort"] = "id"
    signedRequest.query["page_size"] = "1"
    let signedPage = waitFor app.dispatch(signedRequest)
    check signedPage.status == Http200
    let signedDocument = parseJson(signedPage.body)
    check signedDocument["next_cursor"].getStr().startsWith("m2.")
    check decodeCursor(signedDocument["next_cursor"].getStr(), cursorSecret).isSome
    check decodeCursor(signedDocument["next_cursor"].getStr(), "wrong-secret").isNone
    var tamperedRequest = signedRequest
    let tamperedSuffix = if signedCursor[^1] == '0': "1" else: "0"
    tamperedRequest.query["cursor"] = signedCursor[0 .. ^2] & tamperedSuffix
    check (waitFor app.dispatch(tamperedRequest)).status == Http400
    let expired = encodeCursor(integerValue(1), cursorSecret, 10, 100)
    check decodeCursor(expired, cursorSecret, 110).isNone

  test "admin registry protects and audits metadata CRUD routes":
    var metadata = newModelMetadata("AdminItem", "admin_items")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("title", modelString))
    ## A server-managed field may be omitted from the client payload; the
    ## storage layer can supply its value or preserve null as the default.
    metadata.addField(newModelField("status", modelString, nullable = true))
    let registry = newAdminRegistry()
    var adminQueryOptions = defaultQueryComponentOptions()
    adminQueryOptions.defaultPageSize = 2
    adminQueryOptions.maxPageSize = 2
    let adminPolicy = newAuthorizationPolicy()
    for action in ["list", "create", "read", "update", "delete"]:
      adminPolicy.grantPermission("admin", "items", action)
    adminPolicy.assignRole("admin-1", "admin")
    proc authorize(request: Request): bool {.gcsafe.} =
      request.headers.getOrDefault("x-admin") == "yes"
    let customLayout: AdminFormLayoutRenderer = proc(
        context: AdminFormLayoutContext): mahanaim.Response {.gcsafe.} =
      htmlResponse("<section data-resource=\"" & context.resourceName &
        "\">custom layout</section>")
    registry.registerAdminResource("items", "/admin/items", metadata,
      newInMemoryResourceStore(metadata), authorize,
      defaultSecurityPolicy(), adminPolicy, adminQueryOptions,
      @["status"], @["title"], customLayout)
    check registry.resources[0].readOnlyFields == @["status"]
    check registry.resources[0].customColumns == @["title"]
    let app = newApplication()
    registerAdminRoutes(app, registry)

    let denied = waitFor app.dispatch(newRequest("GET", "/admin/items"))
    check denied.status == Http403
    var oversizedAdminQuery = newRequest("GET", "/admin/items")
    oversizedAdminQuery.headers["x-admin"] = "yes"
    oversizedAdminQuery.auth = AuthContext(authenticated: true, subject: "admin-1")
    oversizedAdminQuery.query["page_size"] = "3"
    check (waitFor app.dispatch(oversizedAdminQuery)).status == Http400
    var wrongRole = newRequest("GET", "/admin/items/new")
    wrongRole.headers["x-admin"] = "yes"
    wrongRole.auth = AuthContext(authenticated: true, subject: "admin-2")
    check (waitFor app.dispatch(wrongRole)).status == Http403
    var authorized = newRequest("GET", "/admin/items/new")
    authorized.headers["x-admin"] = "yes"
    authorized.auth = AuthContext(authenticated: true, subject: "admin-1")
    let form = waitFor app.dispatch(authorized)
    check form.status == Http200
    check form.body.contains("data-resource=\"items\"")
    check form.body.contains("custom layout")

    var createRequest = newRequest("POST", "/admin/items",
      "{\"title\":\"first\",\"status\":\"forged\"}")
    createRequest.headers["x-admin"] = "yes"
    createRequest.auth = AuthContext(authenticated: true, subject: "admin-1")
    let created = waitFor app.dispatch(createRequest)
    check created.status == Http201
    let createdDocument = parseJson(created.body)
    let id = createdDocument["id"].getInt()
    check not (createdDocument.hasKey("status") and
      createdDocument["status"].kind == JString and
      createdDocument["status"].getStr() == "forged")
    check registry.auditLog.len == 1
    check registry.auditLog[0].action == "create"
    check registry.auditEvents()[0].actor == "admin-1"
    var customList = newRequest("GET", "/admin/items")
    customList.headers["x-admin"] = "yes"
    customList.auth = authorized.auth
    let customListResponse = waitFor app.dispatch(customList)
    check parseJson(customListResponse.body)[0].hasKey("title")
    check parseJson(customListResponse.body)[0].hasKey("id") == false
    check parseJson(customListResponse.body)[0].hasKey("status") == false
    var snapshot = registry.auditEvents()
    snapshot[0].action = "tampered"
    check registry.auditEvents()[0].action == "create"

    var updateRequest = newRequest("PUT", "/admin/items/" & $id,
      "{\"title\":\"updated\",\"status\":\"forged-again\"}")
    updateRequest.headers["x-admin"] = "yes"
    updateRequest.auth = authorized.auth
    check (waitFor app.dispatch(updateRequest)).status == Http200
    var inlineRequest = newRequest("PATCH", "/admin/items/" & $id & "/inline",
      "{\"title\":\"inline updated\",\"status\":\"forged-inline\"}")
    inlineRequest.headers["x-admin"] = "yes"
    inlineRequest.auth = authorized.auth
    let inlineResponse = waitFor app.dispatch(inlineRequest)
    check inlineResponse.status == Http200
    check parseJson(inlineResponse.body)["title"].getStr() == "inline updated"
    check parseJson(inlineResponse.body).hasKey("status") == false
    var deleteRequest = newRequest("DELETE", "/admin/items/" & $id)
    deleteRequest.headers["x-admin"] = "yes"
    deleteRequest.auth = authorized.auth
    check (waitFor app.dispatch(deleteRequest)).status == Http204
    check registry.auditLog.len == 4
    check registry.auditLog[1].action == "update"
    check registry.auditLog[2].action == "inline-update"
    check registry.auditLog[3].action == "delete"

    var bulkCreate = newRequest("POST", "/admin/items",
      "{\"title\":\"second\"}")
    bulkCreate.headers["x-admin"] = "yes"
    bulkCreate.auth = authorized.auth
    let secondCreated = waitFor app.dispatch(bulkCreate)
    let secondId = parseJson(secondCreated.body)["id"].getInt()
    var bulkDelete = newRequest("POST", "/admin/items/bulk-delete",
      "{\"ids\":[\"" & $secondId & "\",\"missing\"]}")
    bulkDelete.headers["x-admin"] = "yes"
    bulkDelete.auth = authorized.auth
    let bulkDeleted = waitFor app.dispatch(bulkDelete)
    check bulkDeleted.status == Http200
    check parseJson(bulkDeleted.body)["deleted"].getInt() == 1
    check registry.auditLog[^1].action == "delete"

    var invalidQuery = newRequest("GET", "/admin/items")
    invalidQuery.headers["x-admin"] = "yes"
    invalidQuery.auth = authorized.auth
    invalidQuery.query["page_size"] = "bad"
    let rejectedQuery = waitFor app.dispatch(invalidQuery)
    check rejectedQuery.status == Http400
    check rejectedQuery.headers["content-type"] == "application/problem+json"
    check registry.runAdminCli(["resources"]) == 0
    check registry.runAdminCli(["audit"]) == 0
    expect ValueError:
      discard registry.runAdminCli(["delete", "items"])

  test "query component validates bounded pagination filters sorting and fields":
    var metadata = newModelMetadata("QueryUser", "query_users")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("active", modelBoolean))
    metadata.addField(newModelField("score", modelFloat))
    metadata.addField(newModelField("name", modelString))
    var request = newRequest("GET", "/users")
    request.query["page"] = "2"
    request.query["page_size"] = "10"
    request.query["fields"] = "name,id"
    request.query["sort"] = "-score,name"
    request.query["filter.id__gte"] = "10"
    request.query["filter.active"] = "true"
    let parsed = request.parseQueryComponent(metadata.fields)
    check parsed.valid
    check parsed.pagination.page == 2
    check parsed.pagination.pageSize == 10
    check parsed.query.offset == 10
    check parsed.query.columns == @["name", "id"]
    check parsed.query.orderBy[0].field == "score"
    check parsed.query.orderBy[0].descending
    var idFilter: QueryFilter
    var activeFilter: QueryFilter
    for currentFilter in parsed.query.filters:
      if currentFilter.field == "id": idFilter = currentFilter
      if currentFilter.field == "active": activeFilter = currentFilter
    check idFilter.operator == filterGreaterOrEqual
    check idFilter.value.kind == sqlInteger
    check idFilter.value.integer == 10
    check activeFilter.value.boolean

    var cursorRequest = newRequest("GET", "/users")
    cursorRequest.query["cursor"] = "20"
    cursorRequest.query["sort"] = "-id"
    let cursorParsed = cursorRequest.parseQueryComponent(metadata.fields,
      QueryComponentOptions(defaultPage: 1, defaultPageSize: 5,
        maxPageSize: 50, cursorField: "id"))
    check cursorParsed.valid
    check cursorParsed.cursor.isSome
    check cursorParsed.cursor.get().field == "id"
    check cursorParsed.cursor.get().descending
    check cursorParsed.cursor.get().value.integer == 20
    check cursorParsed.query.filters[^1].operator == filterLess
    check cursorParsed.query.orderBy[0].field == "id"
    let cursorToken = encodeCursor(integerValue(20))
    check decodeCursor(cursorToken).get().integer == 20
    let signedToken = encodeCursor(textValue("Ada"), "query-secret", 30, 1000)
    check decodeCursor(signedToken, "query-secret", 1029).get().text == "Ada"
    check decodeCursor(signedToken, "query-secret", 1030).isNone

    var aggregateRequest = newRequest("GET", "/users/report")
    aggregateRequest.query["group_by"] = "active"
    aggregateRequest.query["aggregate.count"] = "*"
    aggregateRequest.query["aggregate.sum"] = "score"
    let aggregateParsed = parseAggregateComponent(aggregateRequest,
      "query_users", metadata.fields)
    check aggregateParsed.valid
    check aggregateParsed.query.query.groupBy == @["active"]
    check aggregateParsed.query.query.aggregates.len == 2
    check aggregateParsed.query.compile().sql ==
      "SELECT \"active\", COUNT(*) AS \"count_all\", SUM(\"score\") AS \"sum_score\" FROM \"query_users\" GROUP BY \"active\""
    var invalidAggregate = newRequest("GET", "/users/report")
    invalidAggregate.query["aggregate.sum"] = "*"
    let rejectedAggregate = parseAggregateComponent(invalidAggregate,
      "query_users", metadata.fields)
    check not rejectedAggregate.valid
    check rejectedAggregate.errors[0].code == "invalid_wildcard"

    var invalidCursor = newRequest("GET", "/users")
    invalidCursor.query["cursor"] = "20"
    let rejectedCursor = invalidCursor.parseQueryComponent(metadata.fields)
    check not rejectedCursor.valid
    check rejectedCursor.errors[0].code == "cursor_field_required"

    var invalid = newRequest("GET", "/users")
    invalid.query["page_size"] = "1000"
    invalid.query["fields"] = "unknown"
    invalid.query["filter.active"] = "maybe"
    let rejected = invalid.parseQueryComponent(metadata.fields)
    check not rejected.valid
    check rejected.errors.len == 3

  test "MessagePack encoder is deterministic and preserves serializer validity":
    let document = parseJson("{\"b\":true,\"a\":1,\"items\":[null,\"ok\"]}")
    let encoded = toMessagePack(document)
    ## The map has three keys and sorted encoding starts with `a`.
    check ord(encoded[0]) == 0x83
    check ord(encoded[1]) == 0xA1
    check encoded[2] == 'a'
    check toMessagePack(document) == encoded
    check fromMessagePack(encoded) == document
    check fromMessagePack(toMessagePack(parseJson("-42.5"))).getFloat() == -42.5
    expect ValueError:
      discard fromMessagePack(encoded & "\x00")
    expect ValueError:
      discard fromMessagePack("\x81\x01\x01")
    let invalid = SerializationResult(document: document,
      errors: @[SerializationIssue(field: "a", code: "invalid",
        message: "invalid")])
    expect ValueError:
      discard serializeMessagePack(invalid)
    let response = messagePackResponse(document)
    check response.status == Http200
    check response.headers["content-type"] == "application/msgpack"
    check response.body == encoded
    let defaultNegotiated = negotiateJsonMessagePack(
      newRequest("GET", "/messages"), document)
    check defaultNegotiated.headers["content-type"].startsWith("application/json")
    var messagePackRequest = newRequest("GET", "/messages")
    messagePackRequest.headers["accept"] = "application/msgpack"
    let negotiatedMessagePack = negotiateJsonMessagePack(messagePackRequest, document)
    check negotiatedMessagePack.headers["content-type"] == "application/msgpack"
    check negotiatedMessagePack.body == encoded
    let streamed = negotiateJsonMessagePackStream(messagePackRequest, document)
    check streamed.representation == rrStream
    check streamed.headers["content-type"] == "application/msgpack"
    check streamed.body == encoded
    check streamed.headers["vary"] == "Accept"
    var unsupportedRequest = newRequest("GET", "/messages")
    unsupportedRequest.headers["accept"] = "application/xml"
    check negotiateJsonMessagePack(unsupportedRequest, document).status == Http406
    check negotiateJsonMessagePackStream(unsupportedRequest, document).status == Http406
    let invalidStream = SerializationResult(document: document,
      errors: @[SerializationIssue(field: "a", code: "invalid",
        message: "invalid")])
    expect ValueError:
      discard messagePackStreamResponse(invalidStream)

  test "database query compiler binds values for SQLite and PostgreSQL":
    let query = SelectQuery(
      table: "users",
      columns: @[
        "id", "email"],
      filters: @[
        QueryFilter(field: "active", operator: filterEqual,
          value: booleanValue(true)),
        QueryFilter(field: "email", operator: filterLike,
          value: textValue("%@example.test"))],
      orderBy: @[QueryOrder(field: "id", descending: true)],
      limit: 20,
      offset: 40)
    let sqlite = compileSelect(query)
    check sqlite.sql == "SELECT \"id\", \"email\" FROM \"users\" WHERE \"active\" = ? AND \"email\" LIKE ? ORDER BY \"id\" DESC LIMIT 20 OFFSET 40"
    check sqlite.parameters.len == 2
    let postgres = compileSelect(query, dialectPostgres)
    check postgres.sql.contains("= $1")
    check postgres.sql.contains("LIKE $2")
    check capabilitiesForDialect(dialectSqlite).supportsTransactions
    check not capabilitiesForDialect(dialectSqlite).supportsIsolation
    let postgresCapabilities = capabilitiesForDialect(dialectPostgres)
    check postgresCapabilities.supportsIsolation
    check postgresCapabilities.supportsRowLocks
    check not capabilitiesForDialect(dialectSqlite).supportsRowLocks
    check isolationSerializable in postgresCapabilities.isolationLevels
    let locked = newQuerySet("users").selectFields(["id"]).lockRows(lockForUpdate)
    check compile(locked, dialectPostgres).sql.endsWith(" FOR UPDATE")
    expect ValueError:
      discard compile(locked, dialectSqlite)
    let aggregateLock = newQuerySet("users").selectFields(["id"]).
      addAggregate(aggregateCount, "*", "total").lockRows(lockForShare)
    expect ValueError:
      discard compile(aggregateLock, dialectPostgres)
    let paged = compileSelect(query.withPagination(newPagination(3, 10, 50)))
    check paged.sql.endsWith("LIMIT 10 OFFSET 20")
    let batched = compileSelect(SelectQuery(table: "posts", columns: @["id"],
      filters: @[QueryFilter(field: "user_id", operator: filterIn,
        value: listValue([integerValue(1), integerValue(2)]))]), dialectPostgres)
    check batched.sql.contains("\"user_id\" IN ($1, $2)")
    check batched.parameters.len == 2
    expect ValueError:
      discard newPagination(0, 10)
    expect ValueError:
      discard compileSelect(SelectQuery(table: "users; DROP TABLE users", columns: @["id"]))

    let migration = migrationSql(MigrationOperation(
      kind: migrationCreateIndex,
      table: "users",
      index: ModelIndex(name: "users_email_idx", fields: @["email"], unique: true)))
    check migration == "CREATE UNIQUE INDEX \"users_email_idx\" ON \"users\" (\"email\")"

    let adapter = FakeDatabaseAdapter(events: @[])
    adapter.withTransaction(proc() {.gcsafe.} = discard)
    check adapter.events == @["begin", "commit"]
    expect ValueError:
      adapter.withTransaction(proc() {.gcsafe.} =
        raise newException(ValueError, "transaction failure"))
    check adapter.events == @["begin", "commit", "begin", "rollback"]

  test "QuerySet builder compiles grouped aggregates for both database dialects":
    let base = newQuerySet("orders")
    let grouped = base
      .selectFields(@["status"])
      .whereFilter(QueryFilter(field: "active", operator: filterEqual,
        value: booleanValue(true)))
      .addAggregate(aggregateCount, "*", "total")
      .addAggregate(aggregateSum, "amount", "gross")
      .addAggregate(aggregateAverage, "amount", "mean")
      .groupByFields(@["status"])
      .orderByField("status")
      .paginate(newPagination(2, 10, 50))
    check base.query.filters.len == 0
    check base.query.aggregates.len == 0
    let sqlite = grouped.compile()
    check sqlite.sql == "SELECT \"status\", COUNT(*) AS \"total\", SUM(\"amount\") AS \"gross\", AVG(\"amount\") AS \"mean\" FROM \"orders\" WHERE \"active\" = ? GROUP BY \"status\" ORDER BY \"status\" ASC LIMIT 10 OFFSET 10"
    check sqlite.parameters.len == 1
    check sqlite.parameters[0].kind == sqlBoolean
    check sqlite.parameters[0].boolean
    let postgres = grouped.compile(dialectPostgres)
    check postgres.sql.contains("WHERE \"active\" = $1")
    check postgres.sql.contains("GROUP BY \"status\"")
    check postgres.sql.endsWith("LIMIT 10 OFFSET 10")

    expect ValueError:
      discard newQuerySet("orders").addAggregate(aggregateCount, "*", "")
        .compile()
    expect ValueError:
      discard newQuerySet("orders").addAggregate(aggregateSum, "amount;DROP", "gross")
        .compile()

  test "QuerySet annotation compiles typed arithmetic without raw SQL":
    let query = newQuerySet("orders").selectFields(@["id", "amount"]).
      annotateFields(annotationAdd, "amount", "id", "total")
    check query.compile().sql ==
      "SELECT \"id\", \"amount\", \"amount\" + \"id\" AS \"total\" FROM \"orders\""
    expect ValueError:
      discard newQuerySet("orders").selectFields(@["id"]).
        annotateFields(annotationAdd, "", "id", "total").compile()
    expect ValueError:
      discard newQuerySet("orders").selectFields(@["id"]).
        annotateFields(annotationAdd, "id", "amount", "").compile()

  test "template engine escapes context and composes inheritance includes filters":
    let engine = newTemplateEngine()
    engine.registerTemplate("base", "<main>{% block content %}fallback{% endblock %}</main>")
    engine.registerTemplate("badge", "<span>{{ label|upper }}</span>")
    engine.registerTemplate("page", "{% extends \"base\" %}" &
      "{% block content %}<h1>{{ title }}</h1>{% include \"badge\" %}{% endblock %}")
    var context: TemplateContext
    context["title"] = "<Ada>"
    context["label"] = "nim"
    let output = engine.render("page", context)
    check output == "<main><h1>&lt;Ada&gt;</h1><span>NIM</span></main>"
    engine.registerTranslation("en", "welcome", "Welcome")
    engine.registerTranslation("ko", "welcome", "환영합니다")
    check engine.translate("welcome", "ko") == "환영합니다"
    check engine.translate("welcome", "ja") == "Welcome"
    check engine.translate("missing", "ko") == "missing"
    let catalogPath = getTempDir() / "mahanaim_translation_catalog.json"
    writeFile(catalogPath, "{\"welcome\":\"안녕하세요\",\"logout\":\"로그아웃\"}")
    try:
      let fileEngine = newTemplateEngine()
      fileEngine.loadTranslationFile("ko", catalogPath)
      check fileEngine.translate("welcome", "ko") == "안녕하세요"
      check fileEngine.translate("logout", "ko") == "로그아웃"
    finally:
      if fileExists(catalogPath): removeFile(catalogPath)
    let catalogDirectory = getTempDir() / "mahanaim_translation_directory_test"
    if dirExists(catalogDirectory):
      removeDir(catalogDirectory)
    createDir(catalogDirectory)
    let enCatalog = catalogDirectory / "en.json"
    let koCatalog = catalogDirectory / "ko-KR.json"
    let ignoredCatalog = catalogDirectory / "ignored.txt"
    writeFile(enCatalog, "{\"welcome\":\"Directory welcome\"}")
    writeFile(koCatalog, "{\"welcome\":\"디렉터리 환영\"}")
    writeFile(ignoredCatalog, "not a JSON catalog")
    try:
      let directoryEngine = newTemplateEngine()
      directoryEngine.loadTranslationDirectory(catalogDirectory, "json")
      check directoryEngine.translate("welcome", "en") == "Directory welcome"
      check directoryEngine.translate("welcome", "ko-KR") == "디렉터리 환영"
      expect ValueError:
        directoryEngine.loadTranslationDirectory(catalogDirectory / "missing")
    finally:
      if fileExists(enCatalog): removeFile(enCatalog)
      if fileExists(koCatalog): removeFile(koCatalog)
      if fileExists(ignoredCatalog): removeFile(ignoredCatalog)
      if dirExists(catalogDirectory): removeDir(catalogDirectory)
    let invalidCatalogPath = getTempDir() / "mahanaim_invalid_translation.json"
    writeFile(invalidCatalogPath, "{\"welcome\":true}")
    try:
      expect ValueError:
        newTemplateEngine().loadTranslationFile("ko", invalidCatalogPath)
    finally:
      if fileExists(invalidCatalogPath): removeFile(invalidCatalogPath)
    expect ValueError:
      engine.registerTranslation("en", "welcome", "Again")
    expect ValueError:
      engine.registerTemplate("base", "duplicate")
    expect ValueError:
      discard engine.render("missing", context)
    engine.registerTag("greet", proc(arguments: seq[string], values: TemplateContext): string =
      let name = if arguments.len == 1: values.getOrDefault(arguments[0]) else: ""
      "Hello <" & name & ">")
    engine.registerTemplate("tags", "{% if visible %}{% tag greet title %}{% else %}hidden{% endif %}")
    context["visible"] = "true"
    check engine.render("tags", context) == "Hello &lt;&lt;Ada&gt;&gt;"
    context["visible"] = "false"
    check engine.render("tags", context) == "hidden"
    expect ValueError:
      engine.registerTag("greet", proc(arguments: seq[string], values: TemplateContext): string = "again")
    engine.registerTemplate("unknown-tag", "{% tag missing value %}")
    expect ValueError:
      discard engine.render("unknown-tag", context)
    engine.registerTemplate("cycle-a", "{% include \"cycle-b\" %}")
    engine.registerTemplate("cycle-b", "{% include \"cycle-a\" %}")
    expect ValueError:
      discard engine.render("cycle-a", context)

  test "relation query compiler emits safe deterministic joins":
    let query = RelationSelectQuery(
      table: "users", alias: "u", columns: @["u.id", "posts.title"],
      joins: @[RelationJoin(kind: relationLeftJoin, table: "posts",
        alias: "posts", localTable: "u", localField: "id",
        foreignField: "user_id")],
      filters: @[QueryFilter(field: "posts.title", operator: filterLike,
        value: textValue("%nim%"))],
      orderBy: @[QueryOrder(field: "posts.title", descending: false)],
      limit: 10, offset: 20)
    let compiled = compileRelationSelect(query, dialectPostgres)
    check compiled.sql.contains("LEFT JOIN \"posts\" AS \"posts\"")
    check compiled.sql.contains("\"u\".\"id\" = \"posts\".\"user_id\"")
    check compiled.sql.contains("\"posts\".\"title\" LIKE $1")
    check compiled.sql.contains("LIMIT 10 OFFSET 20")
    check compiled.parameters.len == 1
    check compiled.parameters[0].kind == sqlText
    check compiled.parameters[0].text == "%nim%"
    expect ValueError:
      discard compileRelationSelect(RelationSelectQuery(
        table: "users", alias: "u", columns: @["u.id"],
        joins: @[RelationJoin(table: "posts", alias: "u",
          localTable: "u", localField: "id", foreignField: "user_id")]))

  test "SQLite adapter executes bound CRUD and transactional migrations":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"users\" (\"id\" INTEGER, \"name\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"users\" (\"id\", \"name\") VALUES (?, ?)",
      parameters: @[integerValue(1), textValue("Ada")]))
    let selected = adapter.execute(CompiledQuery(sql:
      "SELECT \"id\", \"name\" FROM \"users\"", parameters: @[]))
    check selected.len == 1
    check selected[0][0].kind == sqlInteger
    check selected[0][0].integer == 1
    check selected[0][1].text == "Ada"
    let typedResult = adapter.executeResult(CompiledQuery(sql:
      "SELECT \"id\", \"name\" FROM \"users\"", parameters: @[]))
    check typedResult.columns.len == 2
    check typedResult.columns[0].name == "id"
    check typedResult.columns[0].kind == sqlInteger
    check typedResult.columns[1].name == "name"
    check typedResult.columns[1].kind == sqlText
    check typedResult.rows[0][0].integer == 1

    adapter.withTransaction(proc() =
      discard adapter.execute(CompiledQuery(sql:
        "INSERT INTO \"users\" (\"id\", \"name\") VALUES (?, ?)",
        parameters: @[integerValue(2), textValue("Grace")])))
    let failingTransaction: TransactionCallback = proc() =
      discard adapter.execute(CompiledQuery(sql:
        "INSERT INTO \"users\" (\"id\", \"name\") VALUES (?, ?)",
        parameters: @[integerValue(3), textValue("Rollback")]))
      raise newException(ValueError, "rollback test")
    expect ValueError:
      adapter.withTransaction(failingTransaction)
    adapter.begin()
    adapter.savepoint("before_insert")
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"users\" (\"id\", \"name\") VALUES (?, ?)",
      parameters: @[integerValue(4), textValue("Savepoint")] ))
    adapter.rollbackToSavepoint("before_insert")
    adapter.releaseSavepoint("before_insert")
    adapter.commit()
    let afterRollback = adapter.execute(CompiledQuery(sql:
      "SELECT \"id\" FROM \"users\"", parameters: @[]))
    check afterRollback.len == 2

    let migrationAdapter = newSqliteDatabaseAdapter()
    defer: migrationAdapter.close()
    migrationAdapter.applyMigration(Migration(name: "audit", up: @[
      MigrationOperation(kind: migrationCreateTable, table: "audit",
        field: ModelField(name: "message", kind: modelString))], down: @[
      MigrationOperation(kind: migrationDropTable, table: "audit")]))
    discard migrationAdapter.execute(CompiledQuery(sql:
      "INSERT INTO \"audit\" (\"message\") VALUES (?)",
      parameters: @[textValue("created")]))
    check migrationAdapter.execute(CompiledQuery(sql:
      "SELECT \"message\" FROM \"audit\"", parameters: @[]))[0][0].text == "created"

    let historyAdapter = newSqliteDatabaseAdapter()
    defer: historyAdapter.close()
    let first = Migration(name: "001_users", up: @[
      MigrationOperation(kind: migrationCreateTable, table: "users",
        field: ModelField(name: "name", kind: modelString))], down: @[
      MigrationOperation(kind: migrationDropTable, table: "users")])
    let second = Migration(name: "002_audit", up: @[
      MigrationOperation(kind: migrationCreateTable, table: "audit_log",
        field: ModelField(name: "message", kind: modelString))], down: @[
      MigrationOperation(kind: migrationDropTable, table: "audit_log")])
    check historyAdapter.migrate([first, second]) == @["001_users", "002_audit"]
    check historyAdapter.migrate([first, second]).len == 0
    check historyAdapter.appliedMigrations() == @["001_users", "002_audit"]
    check historyAdapter.rollbackLatest([first, second]).get() == "002_audit"
    check historyAdapter.appliedMigrations() == @["001_users"]
    ## A rollback requires the latest recorded migration's down definition.
    expect ValueError:
      discard historyAdapter.rollbackLatest([second])
    check historyAdapter.appliedMigrations() == @[
      "001_users"]
    check historyAdapter.rollbackLatest([first]).get() == "001_users"
    check historyAdapter.appliedMigrations().len == 0

  test "migration command contract parses and runs status up and rollback":
    let first = Migration(name: "001_users", up: @[
      MigrationOperation(kind: migrationCreateTable, table: "users",
        field: ModelField(name: "name", kind: modelString))], down: @[
      MigrationOperation(kind: migrationDropTable, table: "users")])
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()

    check parseMigrationCommand(["status"]).kind == migrationCommandStatus
    check parseMigrationCommand(["up"]).kind == migrationCommandUp
    check parseMigrationCommand(["rollback"]).kind == migrationCommandRollback
    expect ValueError:
      discard parseMigrationCommand(["unknown"])

    let up = executeMigrationCommand(adapter, [first],
      parseMigrationCommand(["up"]))
    check up.applied == @["001_users"]
    let status = executeMigrationCommand(adapter, [first],
      parseMigrationCommand(["status"]))
    check status.applied == @["001_users"]
    let rollback = executeMigrationCommand(adapter, [first],
      parseMigrationCommand(["rollback"]))
    check rollback.rolledBack.get() == "001_users"

  test "metadata migration registry and schema diff are deterministic":
    var desired = newModelMetadata("MigrationUser", "migration_users")
    desired.addField(newModelField("id", modelInteger, primaryKey = true))
    desired.addField(newModelField("email", modelString, unique = true))
    desired.addIndex(ModelIndex(name: "idx_migration_users_email",
      fields: @["email"], unique: true))
    let generated = migrationFromMetadata(desired, "001_migration_users")
    check generated.up.len == 3
    check generated.up[0].kind == migrationCreateTable
    check generated.up[1].kind == migrationAddColumn
    check generated.down[0].kind == migrationDropTable

    var current = newModelMetadata("MigrationUser", "migration_users")
    current.addField(newModelField("id", modelInteger, primaryKey = true))
    let diff = diffModelMetadata(current, desired)
    check diff.len == 2
    check diff[0].kind == migrationMissingField
    check diff[1].kind == migrationMissingIndex
    check not schemaMatches(current, desired)
    check schemaMatches(desired, desired)

    let registry = newMigrationRegistry()
    proc migrationProvider(): seq[Migration] {.gcsafe.} =
      @[Migration(name: "001_provider", up: @[], down: @[])]
    registry.registerMigrations(migrationProvider)
    check registry.loadMigrations().len == 1
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard executeMigrationCommand(adapter, [generated],
      parseMigrationCommand(["up"]))

  test "application CLI runs registered SQLite migrations":
    let path = getTempDir() / "mahanaim_cli_migrations.sqlite"
    if fileExists(path):
      removeFile(path)
    defer:
      if fileExists(path):
        removeFile(path)
    let registry = newMigrationRegistry()
    proc cliMigrationProvider(): seq[Migration] {.gcsafe.} =
      @[Migration(name: "001_cli_users", up: @[
        MigrationOperation(kind: migrationCreateTable, table: "cli_users",
          field: ModelField(name: "id", columnName: "id", kind: modelInteger,
            primaryKey: true))], down: @[
        MigrationOperation(kind: migrationDropTable, table: "cli_users")])]
    registry.registerMigrations(cliMigrationProvider)
    let app = newApplication()
    app.configureMigrations(registry, path)
    check app.runCli(["check"]) == 0
    check app.runCli(["db", "status"]) == 0
    check app.runCli(["db", "up"]) == 0
    check app.runCli(["db", "status"]) == 0

    let seeds = newSeedRegistry()
    proc cliSeed(adapter: DatabaseAdapter) {.gcsafe.} =
      discard adapter.execute(CompiledQuery(
        sql: "INSERT INTO \"cli_users\" (\"id\") VALUES (?)",
        parameters: @[integerValue(1)]))
    seeds.registerSeed(SeedDefinition(name: "001_cli_user", handler: cliSeed))
    app.configureSeeds(seeds)
    check app.runCli(["db", "seed"]) == 0
    let verifyAdapter = newSqliteDatabaseAdapter(path)
    defer: verifyAdapter.close()
    check verifyAdapter.execute(CompiledQuery(
      sql: "SELECT \"id\" FROM \"cli_users\"", parameters: @[])).len == 1
    check app.runCli(["db", "rollback"]) == 0

    let invalidApp = newApplication()
    invalidApp.config.port = 0
    check invalidApp.runCli(["check"]) == 1

  test "database test fixture rolls back each isolated operation":
    let fixture = newDatabaseTestFixture(
      proc(): DatabaseAdapter {.gcsafe.} = newSqliteDatabaseAdapter(),
      proc(adapter: DatabaseAdapter) {.gcsafe.} =
        cast[SqliteDatabaseAdapter](adapter).close())
    defer: fixture.close()

    proc firstFixtureOperation(adapter: DatabaseAdapter) =
      discard adapter.execute(CompiledQuery(sql:
        "CREATE TABLE \"fixture_rows\" (\"value\" TEXT)",
        parameters: @[]))
      discard adapter.execute(CompiledQuery(
        sql: "INSERT INTO \"fixture_rows\" (\"value\") VALUES (?)",
        parameters: @[textValue("rolled back")]))
      let rows = adapter.execute(CompiledQuery(sql:
        "SELECT \"value\" FROM \"fixture_rows\"", parameters: @[]))
      check rows.len == 1
    fixture.withTestDatabase(firstFixtureOperation)

    ## The first operation's DDL and data were both inside the session
    ## transaction, so the next operation receives a clean database state.
    proc secondFixtureOperation(adapter: DatabaseAdapter) =
      discard adapter.execute(CompiledQuery(sql:
        "CREATE TABLE \"fixture_rows\" (\"value\" TEXT)",
        parameters: @[]))
      let rows = adapter.execute(CompiledQuery(sql:
        "SELECT \"value\" FROM \"fixture_rows\"", parameters: @[]))
      check rows.len == 0
    fixture.withTestDatabase(secondFixtureOperation)

  test "database connection pool bounds and safely returns adapters":
    var closed = 0
    let pool = newDatabaseConnectionPool(
      proc(): DatabaseAdapter = newSqliteDatabaseAdapter(), 1,
      proc(adapter: DatabaseAdapter) =
        inc closed
        cast[SqliteDatabaseAdapter](adapter).close())
    let first = pool.acquire()
    check pool.activeCount() == 1
    expect ResourceExhaustedError:
      discard pool.acquire()
    pool.release(first)
    check pool.idleCount() == 1
    pool.withConnection(proc(adapter: DatabaseAdapter) =
      check adapter.dialect == dialectSqlite)
    check pool.idleCount() == 1
    pool.close()
    check closed == 1
    expect ValueError:
      discard pool.acquire()

  test "database repository binds metadata-driven SQLite CRUD":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"users\" (\"id\" INTEGER, \"name\" TEXT, \"active\" INTEGER)",
      parameters: @[]))
    var metadata = newModelMetadata("User", "users")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("name", modelString))
    metadata.addField(newModelField("active", modelBoolean))
    let repository = newDatabaseRepository(metadata, adapter)
    var input: ResourceRow
    input["id"] = newJInt(1)
    input["name"] = newJString("Ada")
    input["active"] = newJBool(true)
    let created = repository.create(input)
    check created["name"].getStr() == "Ada"
    var second: ResourceRow
    second["id"] = newJInt(2)
    second["name"] = newJString("Grace")
    second["active"] = newJBool(true)
    discard repository.create(second)
    check repository.list(SelectQuery(filters: @[
      QueryFilter(field: "active", operator: filterEqual,
        value: booleanValue(true))])).len == 2
    let counted = repository.listWithTotal(SelectQuery(
      filters: @[QueryFilter(field: "active", operator: filterEqual,
        value: booleanValue(true))], limit: 1))
    check counted.rows.len == 1
    check counted.total == 2
    var patch: ResourceRow
    patch["name"] = newJString("Grace")
    let updated = repository.update("1", patch)
    check updated.isSome
    check updated.get()["name"].getStr() == "Grace"
    check repository.delete("1")
    check repository.find("1").isNone

  test "database repository maps annotation aliases by projection":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"scores\" (\"id\" INTEGER, \"points\" INTEGER)",
      parameters: @[]))
    var metadata = newModelMetadata("Score", "scores")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("points", modelInteger))
    let repository = newDatabaseRepository(metadata, adapter)
    var row: ResourceRow
    row["id"] = newJInt(3)
    row["points"] = newJInt(7)
    discard repository.create(row)
    let results = repository.list(newQuerySet("scores").
      selectFields(@["id", "points"]).
      annotateFields(annotationAdd, "points", "id", "total").toSelectQuery())
    check results.len == 1
    check results[0]["id"].getInt() == 3
    check results[0]["points"].getInt() == 7
    check results[0]["total"].getInt() == 10

  test "database repository maps grouped aggregate rows to JSON scalars":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"orders\" (\"id\" INTEGER, \"status\" TEXT, " &
      "\"amount\" INTEGER, \"active\" INTEGER)", parameters: @[]))
    var metadata = newModelMetadata("Order", "orders")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("status", modelString))
    metadata.addField(newModelField("amount", modelInteger))
    metadata.addField(newModelField("active", modelBoolean))
    let repository = newDatabaseRepository(metadata, adapter)
    for values in @[
        (1, "open", 10, true), (2, "open", 15, true),
        (3, "closed", 7, true), (4, "open", 100, false)]:
      var row: ResourceRow
      row["id"] = newJInt(values[0])
      row["status"] = newJString(values[1])
      row["amount"] = newJInt(values[2])
      row["active"] = newJBool(values[3])
      discard repository.create(row)

    let query = newQuerySet("orders")
      .selectFields(@["status"])
      .whereFilter(QueryFilter(field: "active", operator: filterEqual,
        value: booleanValue(true)))
      .addAggregate(aggregateCount, "*", "total")
      .addAggregate(aggregateSum, "amount", "gross")
      .addAggregate(aggregateAverage, "amount", "mean")
      .groupByFields(@["status"])
      .orderByField("status")
    let rows = repository.aggregate(query)
    check rows.len == 2
    check rows[0]["status"].getStr() == "closed"
    check rows[0]["total"].getInt() == 1
    check rows[0]["gross"].getInt() == 7
    check rows[0]["mean"].getFloat() == 7.0
    check rows[1]["status"].getStr() == "open"
    check rows[1]["total"].getInt() == 2
    check rows[1]["gross"].getInt() == 25
    check rows[1]["mean"].getFloat() == 12.5

    var reportRequest = newRequest("GET", "/orders/report")
    reportRequest.query["group_by"] = "status"
    reportRequest.query["filter.active"] = "true"
    reportRequest.query["aggregate.count"] = "*"
    reportRequest.query["aggregate.sum"] = "amount"
    let parsedReport = parseAggregateComponent(reportRequest, "orders",
      metadata.fields)
    check parsedReport.valid
    let parsedRows = repository.aggregate(parsedReport.query)
    check parsedRows.len == 2
    check parsedRows[1]["count_all"].getInt() == 2
    check parsedRows[1]["sum_amount"].getInt() == 25
    expect ValueError:
      discard repository.list(query.toSelectQuery())

  test "aggregate route exposes repository results and structured failures":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"report_items\" (\"id\" INTEGER, " &
      "\"category\" TEXT, \"amount\" INTEGER)", parameters: @[]))
    var metadata = newModelMetadata("ReportItem", "report_items")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("category", modelString))
    metadata.addField(newModelField("amount", modelInteger))
    let repository = newDatabaseRepository(metadata, adapter)
    for values in @[(1, "a", 2), (2, "a", 3), (3, "b", 7)]:
      var row: ResourceRow
      row["id"] = newJInt(values[0])
      row["category"] = newJString(values[1])
      row["amount"] = newJInt(values[2])
      discard repository.create(row)

    proc reportFactory(request: Request): QuerySet {.gcsafe.} =
      discard request
      newQuerySet("report_items")
        .selectFields(@["category"])
        .addAggregate(aggregateSum, "amount", "total")
        .groupByFields(@["category"])
        .orderByField("category")
    proc invalidReportFactory(request: Request): QuerySet {.gcsafe.} =
      discard request
      newQuerySet("report_items").addAggregate(aggregateSum,
        "missing", "total")

    let app = newApplication()
    registerAggregateRoute(app, repository, "/reports/items", "reports.items",
      reportFactory)
    registerAggregateRoute(app, repository, "/reports/invalid", "reports.invalid",
      invalidReportFactory)
    let response = waitFor app.dispatch(newRequest("GET", "/reports/items"))
    check response.status == Http200
    let document = parseJson(response.body)
    check document.len == 2
    check document[0]["category"].getStr() == "a"
    check document[0]["total"].getInt() == 5
    check document[1]["total"].getInt() == 7

    let rejected = waitFor app.dispatch(newRequest("GET", "/reports/invalid"))
    check rejected.status == Http400
    check rejected.headers["content-type"] == "application/problem+json"
    check parseJson(rejected.body)["errors"][0]["code"].getStr() ==
      "invalid_aggregate"

  test "database repository store connects CRUD routes to SQLite":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"route_items\" (" &
      "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"title\" TEXT)",
      parameters: @[]))
    var metadata = newModelMetadata("RouteItem", "route_items")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("title", modelString))
    let repository = newDatabaseRepository(metadata, adapter)
    let resource = newCrudResource(metadata,
      newDatabaseRepositoryResourceStore(repository))
    let app = newApplication()
    registerCrudRoutes(app, resource, "/route-items", "route-items")

    let created = waitFor app.dispatch(newRequest("POST", "/route-items",
      "{\"title\":\"first\"}"))
    check created.status == Http201
    let id = parseJson(created.body)["id"].getInt()
    check parseJson(created.body)["title"].getStr() == "first"
    let updated = waitFor app.dispatch(newRequest("PUT",
      "/route-items/" & $id, "{\"title\":\"updated\"}"))
    check updated.status == Http200
    check parseJson(updated.body)["title"].getStr() == "updated"
    check (waitFor app.dispatch(newRequest("GET",
      "/route-items/" & $id))).status == Http200
    check (waitFor app.dispatch(newRequest("DELETE",
      "/route-items/" & $id))).status == Http204
    check (waitFor app.dispatch(newRequest("GET",
      "/route-items/" & $id))).status == Http404

  test "admin registry composes database repository store with SQLite":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"admin_route_items\" (" &
      "\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"title\" TEXT)",
      parameters: @[]))
    var metadata = newModelMetadata("AdminRouteItem", "admin_route_items")
    metadata.addField(newModelField("id", modelInteger, primaryKey = true))
    metadata.addField(newModelField("title", modelString))
    let repository = newDatabaseRepository(metadata, adapter)
    let registry = newAdminRegistry()
    proc authorize(request: Request): bool {.gcsafe.} =
      request.headers.getOrDefault("x-admin") == "yes"
    registry.registerAdminResource("route-items", "/admin/route-items", metadata,
      newDatabaseRepositoryResourceStore(repository), authorize)
    let app = newApplication()
    registerAdminRoutes(app, registry)

    var createRequest = newRequest("POST", "/admin/route-items",
      "{\"title\":\"stored in sqlite\"}")
    createRequest.headers["x-admin"] = "yes"
    createRequest.auth = AuthContext(authenticated: true, subject: "admin-db")
    let created = waitFor app.dispatch(createRequest)
    check created.status == Http201
    let id = parseJson(created.body)["id"].getInt()

    var listRequest = newRequest("GET", "/admin/route-items")
    listRequest.headers["x-admin"] = "yes"
    listRequest.auth = createRequest.auth
    let listed = waitFor app.dispatch(listRequest)
    check listed.status == Http200
    check parseJson(listed.body)[0]["title"].getStr() == "stored in sqlite"

    var deleteRequest = newRequest("DELETE", "/admin/route-items/" & $id)
    deleteRequest.headers["x-admin"] = "yes"
    deleteRequest.auth = createRequest.auth
    check (waitFor app.dispatch(deleteRequest)).status == Http204
    check registry.auditEvents().len == 2

  test "database repository executes metadata-driven relation joins":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"users\" (\"id\" INTEGER, \"name\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"posts\" (\"id\" INTEGER, \"user_id\" INTEGER, \"title\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"users\" VALUES (?, ?)",
      parameters: @[integerValue(1), textValue("Ada")]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"posts\" VALUES (?, ?, ?)",
      parameters: @[integerValue(10), integerValue(1), textValue("Nim")]))
    var user = newModelMetadata("User", "users")
    user.addField(newModelField("id", modelInteger, primaryKey = true))
    user.addField(newModelField("name", modelString))
    var posts = newModelMetadata("Post", "posts")
    posts.addField(newModelField("id", modelInteger, primaryKey = true))
    posts.addField(newModelField("user_id", modelInteger))
    posts.addField(newModelField("title", modelString))
    var relation = ModelRelation(name: "posts", kind: relationOneToMany,
      targetModel: "Post", localField: "id", foreignField: "user_id")
    let repository = newDatabaseRepository(user, adapter)
    let related = repository.listRelation(relation, posts,
      RelationSelectQuery(filters: @[
        QueryFilter(field: "posts.title", operator: filterEqual,
          value: textValue("Nim"))]))
    check related.len == 1
    check related[0]["name"].getStr() == "Ada"

  test "database repository eager-loads one-hop nested relations":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"users\" (\"id\" INTEGER, \"name\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"posts\" (\"id\" INTEGER, \"user_id\" INTEGER, \"title\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"users\" VALUES (?, ?)",
      parameters: @[integerValue(1), textValue("Ada")]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"users\" VALUES (?, ?)",
      parameters: @[integerValue(2), textValue("Grace")]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"posts\" VALUES (?, ?, ?)",
      parameters: @[integerValue(10), integerValue(1), textValue("Nim")]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"posts\" VALUES (?, ?, ?)",
      parameters: @[integerValue(11), integerValue(2), textValue("Ada")]))
    var user = newModelMetadata("User", "users")
    user.addField(newModelField("id", modelInteger, primaryKey = true))
    user.addField(newModelField("name", modelString))
    var posts = newModelMetadata("Post", "posts")
    posts.addField(newModelField("id", modelInteger, primaryKey = true))
    posts.addField(newModelField("user_id", modelInteger))
    posts.addField(newModelField("title", modelString))
    let userRepository = newDatabaseRepository(user, adapter)
    let usersWithPosts = userRepository.listRelationWithRelated(
      ModelRelation(name: "posts", kind: relationOneToMany,
        targetModel: "Post", localField: "id", foreignField: "user_id"), posts)
    check usersWithPosts.len == 2
    check usersWithPosts[0]["posts"].kind == JArray
    check usersWithPosts[0]["posts"].len == 1
    check usersWithPosts[0]["posts"][0]["title"].getStr() == "Nim"
    check usersWithPosts[1]["posts"].len == 1
    check usersWithPosts[1]["posts"][0]["title"].getStr() == "Ada"
    let pagedUsers = userRepository.listRelationWithRelated(
      ModelRelation(name: "posts", kind: relationOneToMany,
        targetModel: "Post", localField: "id", foreignField: "user_id"), posts,
      RelationSelectQuery(orderBy: @[QueryOrder(field: "id")], limit: 1,
        offset: 1))
    check pagedUsers.len == 1
    check pagedUsers[0]["id"].getInt() == 2
    check pagedUsers[0]["posts"].len == 1
    check pagedUsers[0]["posts"][0]["title"].getStr() == "Ada"
    let postRepository = newDatabaseRepository(posts, adapter)
    let postsWithUser = postRepository.listRelationWithRelated(
      ModelRelation(name: "user", kind: relationManyToOne,
        targetModel: "User", localField: "user_id", foreignField: "id"), user)
    check postsWithUser.len == 2
    check postsWithUser[0]["user"]["name"].getStr() == "Ada"
    check postsWithUser[1]["user"]["name"].getStr() == "Grace"

  test "database repository defers lazy relation queries until load":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"users\" (\"id\" INTEGER, \"name\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"posts\" (\"id\" INTEGER, \"user_id\" INTEGER, \"title\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"posts\" VALUES (?, ?, ?)",
      parameters: @[integerValue(10), integerValue(1), textValue("Nim")]))
    var user = newModelMetadata("User", "users")
    user.addField(newModelField("id", modelInteger, primaryKey = true))
    user.addField(newModelField("name", modelString))
    var posts = newModelMetadata("Post", "posts")
    posts.addField(newModelField("id", modelInteger, primaryKey = true))
    posts.addField(newModelField("user_id", modelInteger))
    posts.addField(newModelField("title", modelString))
    let repository = newDatabaseRepository(user, adapter)
    let loader = newLazyRelationLoader(repository,
      ModelRelation(name: "posts", kind: relationOneToMany,
        targetModel: "Post", localField: "id", foreignField: "user_id"), posts)
    ## Construction did not query users or posts; the first explicit load does.
    let related = loader.load(integerValue(1))
    check related.len == 1
    check related[0]["title"].getStr() == "Nim"
    expect ValueError:
      discard newLazyRelationLoader(repository,
        ModelRelation(name: "members", kind: relationManyToMany,
          targetModel: "Post", localField: "id", foreignField: "user_id"), posts)

  test "database repository eager-loads explicit many-to-many through relation":
    let adapter = newSqliteDatabaseAdapter()
    defer: adapter.close()
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"users\" (\"id\" INTEGER, \"name\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"posts\" (\"id\" INTEGER, \"title\" TEXT)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "CREATE TABLE \"memberships\" (\"user_id\" INTEGER, \"post_id\" INTEGER)",
      parameters: @[]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"users\" VALUES (?, ?)",
      parameters: @[integerValue(1), textValue("Ada")]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"users\" VALUES (?, ?)",
      parameters: @[integerValue(2), textValue("Grace")]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"posts\" VALUES (?, ?)",
      parameters: @[integerValue(10), textValue("Nim")]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"posts\" VALUES (?, ?)",
      parameters: @[integerValue(11), textValue("SQL")]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"memberships\" VALUES (?, ?)",
      parameters: @[integerValue(1), integerValue(10)]))
    discard adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"memberships\" VALUES (?, ?)",
      parameters: @[integerValue(2), integerValue(11)]))
    var user = newModelMetadata("User", "users")
    user.addField(newModelField("id", modelInteger, primaryKey = true))
    user.addField(newModelField("name", modelString))
    var posts = newModelMetadata("Post", "posts")
    posts.addField(newModelField("id", modelInteger, primaryKey = true))
    posts.addField(newModelField("title", modelString))
    let repository = newDatabaseRepository(user, adapter)
    let relation = ModelRelation(name: "posts", kind: relationManyToMany,
      targetModel: "Post", localField: "id", foreignField: "id",
      throughTable: "memberships", throughLocalField: "user_id",
      throughForeignField: "post_id")
    let usersWithPosts = repository.listRelationWithRelated(relation, posts,
      RelationSelectQuery(orderBy: @[QueryOrder(field: "id")]))
    ## Two parents are resolved through one batched through query and one
    ## target query; grouping must not leak Grace's relation into Ada's.
    check usersWithPosts.len == 2
    check usersWithPosts[0]["posts"].kind == JArray
    check usersWithPosts[0]["posts"].len == 1
    check usersWithPosts[0]["posts"][0]["title"].getStr() == "Nim"
    check usersWithPosts[1]["posts"].kind == JArray
    check usersWithPosts[1]["posts"].len == 1
    check usersWithPosts[1]["posts"][0]["title"].getStr() == "SQL"
    let pagedUsers = repository.listRelationWithRelated(relation, posts,
      RelationSelectQuery(orderBy: @[QueryOrder(field: "id")], limit: 1,
        offset: 1))
    check pagedUsers.len == 1
    check pagedUsers[0]["id"].getInt() == 2
    check pagedUsers[0]["posts"].len == 1
    check pagedUsers[0]["posts"][0]["title"].getStr() == "SQL"
    let lazyPosts = newLazyRelationLoader(repository, relation, posts)
    let lazyRelated = lazyPosts.load(integerValue(1))
    check lazyRelated.len == 1
    check lazyRelated[0]["title"].getStr() == "Nim"

  test "application wires and releases request-scoped database connections":
    var closed = 0
    let pool = newDatabaseConnectionPool(
      proc(): DatabaseAdapter = newSqliteDatabaseAdapter(), 1,
      proc(adapter: DatabaseAdapter) =
        inc closed
        cast[SqliteDatabaseAdapter](adapter).close())
    let app = newApplication()
    app.configureDatabasePool(pool)
    proc databaseRoute(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      check request.database != nil
      check request.database.dialect == dialectSqlite
      return textResponse("database-bound")
    app.get("/database-bound", "database-bound", databaseRoute)
    check (waitFor app.dispatch(newRequest("GET", "/database-bound"))).body ==
      "database-bound"
    check pool.idleCount() == 1
    app.startup()
    app.shutdown()
    check closed == 1

  test "database session provides unit-of-work commit and rollback":
    let pool = newDatabaseConnectionPool(
      proc(): DatabaseAdapter = newSqliteDatabaseAdapter(), 1,
      proc(adapter: DatabaseAdapter) = cast[SqliteDatabaseAdapter](adapter).close())
    let setup = pool.acquire()
    discard setup.execute(CompiledQuery(sql:
      "CREATE TABLE \"events\" (\"id\" INTEGER, \"message\" TEXT)",
      parameters: @[]))
    pool.release(setup)
    var session = newDatabaseSession(pool)
    expect ValueError:
      session.setIsolationLevel(isolationSerializable)
    discard session.adapter.execute(CompiledQuery(sql:
      "INSERT INTO \"events\" (\"id\", \"message\") VALUES (?, ?)",
      parameters: @[integerValue(1), textValue("rolled back")]))
    session.rollback()
    session.close()
    let rollbackCheck = pool.acquire()
    check rollbackCheck.execute(CompiledQuery(sql:
      "SELECT \"id\" FROM \"events\"", parameters: @[])).len == 0
    pool.release(rollbackCheck)
    proc commitEvent(current: DatabaseSession) =
      discard current.adapter.execute(CompiledQuery(sql:
        "INSERT INTO \"events\" (\"id\", \"message\") VALUES (?, ?)",
        parameters: @[integerValue(2), textValue("committed")]))
    pool.withDatabaseSession(commitEvent)
    let commitCheck = pool.acquire()
    check commitCheck.execute(CompiledQuery(sql:
      "SELECT \"id\" FROM \"events\"", parameters: @[])).len == 1
    pool.release(commitCheck)
    pool.close()

  test "Redis RESP client encodes atomic counter and parses server TTL":
    let command = encodeFixedWindowCommand("rate:user", 60)
    check command.startsWith("*5\r\n$4\r\nEVAL\r\n")
    check command.contains("$9\r\nrate:user\r\n")
    var received = ""
    let client = newRedisValkeyRespClient(transport =
      proc(payload: string): string =
        received = payload
        "*2\r\n:3\r\n:57\r\n")
    let counter = client.incrementFixedWindow("rate:user", 60)
    check received == command
    check counter.count == 3
    check counter.ttlSeconds == 57
    let stats = client.stats()
    check stats.requests == 1
    check stats.successes == 1
    check stats.failures == 0
    check stats.connections == 0
    check stats.reconnects == 0
    expect ValueError:
      discard parseCounterResponse("*1\r\n:1\r\n")
    expect CatchableError:
      discard parseCounterResponse("-ERR unavailable\r\n")

  test "Redis RESP client completes a real loopback socket exchange":
    var state: RespFixtureState
    state.port.store(0)
    state.ready.store(false)
    state.received.store(false)
    var worker: Thread[ptr RespFixtureState]
    createThread(worker, runRespFixture, addr state)
    while not state.ready.load():
      sleep(1)
    let client = newRedisValkeyRespClient(port = Port(state.port.load()))
    let counter = client.incrementFixedWindow("live:key", 60)
    client.close()
    joinThread(worker)
    check state.received.load()
    check counter.count == 4
    check counter.ttlSeconds == 56
    let stats = client.stats()
    check stats.requests == 1
    check stats.successes == 1
    check stats.connections == 1
    check stats.reconnects == 0

  test "Redis rate limit store reconnects after a dropped socket":
    var state: RedisReconnectFixtureState
    state.port.store(0)
    state.ready.store(false)
    state.connections.store(0)
    var worker: Thread[ptr RedisReconnectFixtureState]
    createThread(worker, runRedisReconnectFixture, addr state)
    while not state.ready.load():
      sleep(1)
    let client = newRedisValkeyRespClient(port = Port(state.port.load()))
    let store = newRedisValkeyRateLimitStore(client, maxRetries = 1)
    let decision = store.consume("reconnect:key", 2, 60)
    client.close()
    joinThread(worker)
    check state.connections.load() == 2
    check decision.allowed
    check decision.remaining == 1
    let stats = client.stats()
    check stats.requests == 2
    check stats.successes == 1
    check stats.failures == 1
    check stats.connections == 2
    check stats.reconnects == 1

  test "explicit input schema projects to OpenAPI constraints":
    let document = openApiDocument("Mahanaim API", "1.0.0", [
      integerField("userId", flPath),
      stringField("q", flQuery, required = false, minLength = 2,
        maxLength = 80),
      stringField("email", flBody)])
    check document["openapi"].getStr() == "3.1.0"
    check document["paths"]["/generated"]["post"]["parameters"][0]["required"].getBool()
    check document["paths"]["/generated"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"]["email"]["type"].getStr() == "string"

  test "OpenAPI document projects a typed response schema":
    let document = openApiDocument("Mahanaim API", "1.0.0",
      [stringField("query", flQuery, required = false)],
      [integerField("id", flBody), stringField("name", flBody)])
    let responseSchema = document["paths"]["/generated"]["post"]["responses"]["200"]
    check responseSchema["content"]["application/json"]["schema"]["properties"]["id"]["type"].getStr() == "integer"
    check responseSchema["content"]["application/json"]["schema"]["required"][0].getStr() == "id"

  test "OpenAPI registry generates multi-route documents and UI routes":
    let registry = newOpenApiRegistry("Mahanaim API", "1.0.0")
    registry.registerOperation(OpenApiOperation(
      httpMethod: "GET", path: "/users/{id}", operationId: "getUser",
      summary: "Read a user",
      requestSchema: @[integerField("id", flPath)],
      responseSchema: @[integerField("id", flBody), stringField("name", flBody)],
      successStatus: 200))
    registry.registerOperation(OpenApiOperation(
      httpMethod: "POST", path: "/users", operationId: "createUser",
      requestSchema: @[stringField("name", flBody)],
      responseSchema: @[integerField("id", flBody)], successStatus: 201))
    registry.registerOperation(OpenApiOperation(
      httpMethod: "POST", path: "/negotiated", operationId: "negotiated",
      requestSchema: @[stringField("name", flBody)],
      responseSchema: @[stringField("status", flBody)],
      requestContentTypes: @["application/json", "application/x-www-form-urlencoded"],
      responseContentTypes: @["application/json", "application/problem+json"],
      successStatus: 200))
    expect ValueError:
      registry.registerOperation(OpenApiOperation(
        httpMethod: "get", path: "/users/{id}", operationId: "duplicate"))

    let document = registry.document()
    check document["paths"]["/users/{id}"]["get"]["operationId"].getStr() == "getUser"
    check document["paths"]["/users"]["post"]["responses"]["201"] != nil
    check document["paths"]["/users/{id}"]["get"]["parameters"][0]["in"].getStr() == "path"
    check document["paths"]["/negotiated"]["post"]["requestBody"]["content"].hasKey(
      "application/x-www-form-urlencoded")
    check document["paths"]["/negotiated"]["post"]["responses"]["200"][
      "content"].hasKey("application/problem+json")
    expect ValueError:
      registry.registerOperation(OpenApiOperation(
        httpMethod: "GET", path: "/invalid-media", operationId: "invalidMedia",
        requestContentTypes: @["application/json; charset=utf-8"]))
    check swaggerUiHtml("/schema.json").contains("/schema.json")
    check redocHtml("/schema.json").contains("spec-url=\"/schema.json\"")

    let app = newApplication()
    registerOpenApiRoutes(app, registry, "/schema.json", "/swagger", "/redoc-ui")
    let jsonResponse = waitFor app.dispatch(newRequest("GET", "/schema.json"))
    check jsonResponse.status == Http200
    check parseJson(jsonResponse.body)["paths"].hasKey("/users")
    check (waitFor app.dispatch(newRequest("GET", "/swagger"))).body.contains("swagger-ui")
    check (waitFor app.dispatch(newRequest("GET", "/redoc-ui"))).body.contains("redoc")

  test "documented route registration keeps router and OpenAPI registry aligned":
    let registry = newOpenApiRegistry("Documented API", "1.0.0")
    let app = newApplication()
    proc documentedHandler(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return jsonResponse(parseJson("{\"ok\":true}"))
    app.addDocumentedRoute(registry, OpenApiOperation(
      httpMethod: "GET", path: "/documented", operationId: "documented",
      summary: "Documented route", requestSchema: @[], responseSchema: @[],
      successStatus: 200), documentedHandler)
    check (waitFor app.dispatch(newRequest("GET", "/documented"))).status == Http200
    check registry.document()["paths"]["/documented"]["get"]["operationId"].getStr() ==
      "documented"
    expect ValueError:
      app.addDocumentedRoute(registry, OpenApiOperation(
        httpMethod: "GET", path: "/documented", operationId: "duplicate",
        requestSchema: @[], responseSchema: @[], successStatus: 200),
        documentedHandler)
    check registry.operations.len == 1

    addTypedDocumentedRoute(app, registry, OpenApiOperation(
      httpMethod: "POST", path: "/typed-profiles", operationId: "typedProfile",
      requestSchema: @[], responseSchema: @[], successStatus: 201),
      CreateProfileDto, ProfileResponseDto, documentedHandler)
    let typedOperation = registry.operations[1]
    check typedOperation.requestSchema.len == 2
    check typedOperation.requestSchema[0].name == "displayName"
    check typedOperation.requestSchema[1].inputType == itInteger
    check typedOperation.responseSchema.len == 2
    check typedOperation.responseSchema[0].name == "id"

    var profile = newModelMetadata("DocumentedProfile", "documented_profiles")
    profile.addField(newModelField("id", modelInteger, primaryKey = true))
    profile.addField(newModelField("displayName", modelString, maxLength = 32))
    app.addModelDocumentedRoute(registry, OpenApiOperation(
      httpMethod: "POST", path: "/profiles", operationId: "createProfile",
      requestSchema: @[], responseSchema: @[], successStatus: 201), profile,
      documentedHandler)
    let profileDocument = registry.document()["paths"]["/profiles"]["post"]
    check profileDocument["requestBody"]["content"]["application/json"][
      "schema"]["properties"]["displayName"]["maxLength"].getInt() == 32
    check profileDocument["responses"]["201"]["content"]["application/json"][
      "schema"]["required"][0].getStr() == "displayName"

  test "OpenAPI CLI exports collected application routes":
    let app = newApplication()
    proc health(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("ok")
    app.get("/cli-health", "cli-health", health)
    let outputPath = getTempDir() / "mahanaim_cli_openapi.json"
    try:
      check app.runCli(["openapi", outputPath]) == 0
      let document = parseJson(readFile(outputPath))
      check document["openapi"].getStr() == "3.1.0"
      check document["paths"]["/cli-health"]["get"][
        "operationId"].getStr() == "cli-health"
      expect ValueError:
        discard app.runCli(["openapi", "one", "too-many"])
    finally:
      if fileExists(outputPath): removeFile(outputPath)

  test "static collect CLI copies deterministic assets and rejects unsafe roots":
    let root = getTempDir() / "mahanaim_static_collect_test"
    if dirExists(root):
      removeDir(root)
    let source = root / "source"
    let nested = source / "css"
    let output = root / "public"
    createDir(nested)
    writeFile(source / "app.js", "console.log('ok');")
    writeFile(nested / "site.css", "body { color: red; }")
    try:
      let app = newApplication()
      check app.runCli(["static", "collect", source, "--output", output]) == 0
      check readFile(output / "app.js") == "console.log('ok');"
      check readFile(output / "css" / "site.css") == "body { color: red; }"
      expect StaticCollectionError:
        discard app.runCli(["static", "collect", source, "--output", output])
      expect StaticCollectionError:
        discard newStaticCollectionPolicy(@[source], source / "nested-output")
    finally:
      if dirExists(root):
        removeDir(root)

  test "object storage and cache adapters preserve backend-neutral contracts":
    let objects = newInMemoryObjectStorage()
    let uploaded = objects.putObject("avatars/user-1.txt", "hello", "text/plain")
    check uploaded.contentType == "text/plain"
    check objects.getObject("avatars/user-1.txt").get().data == "hello"
    check objects.deleteObject("avatars/user-1.txt")
    check objects.getObject("avatars/user-1.txt").isNone
    expect StorageError:
      discard objects.putObject("../escape", "blocked")

    let remote = newS3ObjectTransport(
      proc(bucket, key, data, contentType: string): string =
        if bucket == "assets" and key == "public/logo.svg" and
            data == "<svg/>" and contentType == "image/svg+xml": "etag-1" else: "",
      proc(bucket, key: string): Option[StoredObject] =
        if bucket == "assets" and key == "public/logo.svg":
          some(StoredObject(key: key, data: "<svg/>",
            contentType: "image/svg+xml", etag: "etag-1"))
        else: none(StoredObject),
      proc(bucket, key: string): bool = bucket == "assets" and
        key == "public/logo.svg")
    let s3 = newS3CompatibleObjectStorage("assets", remote, "public")
    check s3.putObject("logo.svg", "<svg/>", "image/svg+xml").etag == "etag-1"
    check s3.getObject("logo.svg").get().key == "logo.svg"
    check s3.deleteObject("logo.svg")
    expect StorageError:
      discard newS3CompatibleObjectStorage("assets", remote, "../private")

    let cache = newInMemoryCacheStore(maxEntries = 2)
    cache.set("user/1", "one")
    cache.set("user/2", "two")
    check cache.get("user/1").get() == "one"
    cache.set("user/3", "three")
    check cache.get("user/2").isNone
    check cache.delete("user/1")
    expect StorageError:
      cache.set("user/4", "bad", ttlSeconds = -1)

    let redisClient = newRedisValkeyRespClient(transport =
      proc(command: string): string =
        if command.contains("GET"):
          "$3\r\none\r\n"
        elif command.contains("DEL"):
          ":1\r\n"
        else:
          "+OK\r\n")
    let redisCache = newRedisCacheStore(redisClient, "test-cache")
    check redisCache.get("remote").get() == "one"
    redisCache.set("remote", "two", ttlSeconds = 30)
    check redisCache.delete("remote")
    check redisClient.stats().requests == 3

  test "admin create-user CLI uses an application-owned provisioning callback":
    let app = newApplication()
    let store = newInMemoryAccountCredentialStore()
    let hasher = newPbkdf2PasswordHasher(iterations = 10_000)
    app.configureAdminUserCreator(newAdminUserCreator(store, hasher))
    putEnv("MAHANAIM_ADMIN_PASSWORD", "cli-only-password")
    try:
      check app.runCli(["admin", "create-user", "admin@example.test",
        "admin-1"]) == 0
      let account = store.findByIdentifier("admin@example.test")
      check account.isSome
      check account.get().subject == "admin-1"
      check account.get().passwordHash != "cli-only-password"
      check hasher.verifyPassword("cli-only-password", account.get().passwordHash)
      expect ValueError:
        discard app.runCli(["admin", "create-user", "admin@example.test"])
    finally:
      delEnv("MAHANAIM_ADMIN_PASSWORD")

  test "OpenAPI route collection discovers plain routes and preserves schemas":
    let app = newApplication()
    proc health(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("ok")
    proc user(request: Request): Future[mahanaim.Response] {.async, gcsafe.} =
      discard request
      return textResponse("user")
    app.get("/health", "health", health)
    app.get("/users/:id<int>", "user.detail", user)
    app.get("/assets/*path", "", user)
    let registry = newOpenApiRegistry("Collected API", "1.0.0")
    registry.registerOperation(OpenApiOperation(
      httpMethod: "GET", path: "/health", operationId: "health",
      requestSchema: @[], responseSchema: @[stringField("status", flBody)],
      successStatus: 200))
    check registry.collectRoutes(app.router) == 2
    check registry.collectRoutes(app.router) == 0
    check registry.operations.len == 3
    check registry.operations[0].responseSchema.len == 1
    check registry.operations[1].operationId == "user.detail"
    let document = registry.document()
    check document["paths"]["/users/{id}"]["get"][
      "operationId"].getStr() == "user.detail"
    check document["paths"]["/users/{id}"]["get"]["parameters"][0][
      "schema"]["type"].getStr() == "integer"
    check document["paths"]["/assets/{path}"]["get"]["operationId"].getStr() ==
      "get.assets.wildcard.path"

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

    ## The no-argument form must inspect the policy supplied to newApplication;
    ## otherwise CLI/CI could report a clean app while runtime middleware is
    ## configured with an invalid security contract.
    let report = checkApplication(app)
    check not report.passed
    check report.issues.len == 3
    check report.issues[0].code == "config.port.invalid"
    check report.issues[1].code == "route.declaration.duplicate"
    check report.issues[2].code == "security.csrf-secret.weak"

  test "framework checks validate migration registry before boot":
    let registry = newMigrationRegistry()
    proc invalidMigrations(): seq[Migration] {.gcsafe.} =
      @[
        Migration(name: "same", up: @[
          MigrationOperation(kind: migrationDropTable, table: "bad name")]),
        Migration(name: "same", up: @[], down: @[])]
    registry.registerMigrations(invalidMigrations)
    let report = checkMigrations(registry, "")
    check not report.passed
    var codes: seq[string] = @[]
    for issue in report.issues:
      codes.add(issue.code)
    check "migration.path.empty" in codes
    check "migration.operation.invalid" in codes
    check "migration.name.duplicate" in codes

  test "model macro generates deterministic backend-neutral metadata":
    let generated = modelMetadata(MacroUser, "MacroUser", "macro_users")
    check generated.name == "MacroUser"
    check generated.tableName == "macro_users"
    check generated.fields.len == 3
    check generated.fields[0].name == "id"
    check generated.fields[0].kind == modelInteger
    check generated.fields[1].kind == modelString
    check generated.fields[2].kind == modelBoolean

  test "input schema macro generates ordered FieldSpec values":
    let generated = inputSchema(MacroUser)
    check generated.len == 3
    check generated[0].name == "id"
    check generated[0].inputType == itInteger
    check generated[1].inputType == itString
    check generated[2].inputType == itBoolean
    check generated[0].location == flBody
    let response = responseSchema(MacroUser)
    check response.len == generated.len
    check response[1].name == "email"
    check response[1].required

  test "model metadata drives validation forms and OpenAPI schema":
    var metadata = newModelMetadata("Profile", "profiles")
    metadata.addField(newModelField("id", modelInteger,
      primaryKey = true))
    metadata.addField(newModelField("name", modelString, maxLength = 24))
    metadata.addField(newModelField("score", modelFloat))
    metadata.addField(newModelField("active", modelBoolean))
    metadata.addField(newModelField("settings", modelJson))
    metadata.addField(newModelField("nickname", modelString, nullable = true))

    let schema = modelInputSchema(metadata, includePrimaryKey = false)
    check schema.len == 5
    check schema[0].name == "name"
    check schema[0].required
    check schema[0].maxLength == 24
    check schema[1].inputType == itFloat
    check schema[2].inputType == itBoolean
    check schema[3].inputType == itJson
    check not schema[4].required

    var request = newRequest("POST", "/profiles")
    request.headers["Content-Type"] = "application/json"
    request.body = "{" &
      "\"name\":\"Ada\",\"score\":\"not-a-number\"," &
      "\"active\":\"maybe\",\"settings\":\"{broken\"}"
    let validation = request.validate(schema)
    check not validation.valid
    check validation.errors[0].code == "invalid_float"
    check validation.errors[1].code == "invalid_boolean"
    check validation.errors[2].code == "invalid_json"

    let form = bindModelForm(request, metadata)
    check form.fields.len == 5
    check form.fields[0].name == "name"
    check form.fields[1].errors[0] == "Value must be a number"

    let widgets = newWidgetRegistry()
    widgets.registerWidget("name", proc(field: FormFieldState): string =
      "<textarea name=\"" & field.name & "\">custom</textarea>")
    let customHtml = renderForm(form, widgets = widgets)
    check "<textarea name=\"name\">custom</textarea>" in customHtml
    expect ValueError:
      widgets.registerWidget("name", proc(field: FormFieldState): string = "")

    var validRow = newRequest("POST", "/profiles", "{\"name\":\"Grace\"}")
    validRow.headers["Content-Type"] = "application/json"
    let formSet = bindModelFormSet([request, validRow], metadata)
    check formSet.forms.len == 2
    check formSet.forms[1].fields[0].value == "Grace"
    check formSet.errors.len > 0
    check renderFormSet(formSet).contains("formset-row")

    let document = modelOpenApiDocument("Profiles", "1.0.0", metadata,
      includePrimaryKey = false)
    let properties = document["paths"]["/generated"]["post"][
      "requestBody"]["content"]["application/json"]["schema"]["properties"]
    check properties["score"]["type"].getStr() == "number"
    check properties["active"]["type"].getStr() == "boolean"
    check properties["settings"]["type"].getStr() == "object"

## Handler execution policy.
##
## Nim's async event loop must never be blocked by accidental synchronous I/O.
## Sync handlers remain explicit in route metadata, and the application
## dispatcher can offload them through the executor contract before awaiting
## their result on the event loop.

import std/[asyncdispatch, httpcore, locks, tables]
import pkg/taskpools
import ./core

type
  ExecutionPolicy* = object
    ## `allowSynchronousHandlers` is permissive for local development; a
    ## production application can set it false and fail during dispatch.
    allowSynchronousHandlers*: bool
    warnOnSynchronousHandlers*: bool
    offloadSynchronousHandlers*: bool

  SyncJob* = proc (): Response {.gcsafe.}

  SharedBuffer = object
    ## Taskpools Flowvar only transports copy-safe values. Managed Nim strings
    ## stay on the worker and cross the boundary through explicitly owned bytes.
    data: pointer
    length: int

  SyncJobResult = object
    ## Keep this result copy-safe: no Table, string, seq, or ref crosses the
    ## worker boundary. The event loop reconstructs the framework Response.
    status: int
    body: SharedBuffer
    headers: SharedBuffer
    failed: bool
    errorKind: int
    errorMessage: SharedBuffer

  ThreadPoolExecutor* = ref object
    ## The executor owns scheduling policy while the taskpool backend remains
    ## process-wide, matching Nim's former threadpool behavior and avoiding a
    ## worker-pool leak for every short-lived test application.
    pollIntervalMs*: int
    ## Zero preserves an unlimited queue; positive values reject new work once
    ## the configured number of worker jobs is in flight.
    maxConcurrentJobs*: int
    activeJobs: int
    pool: Taskpool

var sharedPool: Taskpool
var jobRegistry: ptr Table[int, SyncJob]
var jobRegistryLock: Lock
var nextJobId = 0

initLock(jobRegistryLock)

proc processPool(): Taskpool =
  ## Lazily initialize one backend on the event-loop/root thread. Taskpools
  ## associates spawned work with the calling thread's worker context, so a
  ## single shared pool is safer than constructing one inside every Application.
  if jobRegistry.isNil:
    # The pointer keeps the registry out of Nim's GC global scan. Access is
    # still serialized by jobRegistryLock, and the process owns it until exit.
    jobRegistry = cast[ptr Table[int, SyncJob]](
      allocShared0(sizeof(Table[int, SyncJob])))
    jobRegistry[] = initTable[int, SyncJob]()
  if sharedPool.isNil:
    sharedPool = Taskpool.new()
  sharedPool

proc registerJob(job: SyncJob): int =
  ## Keep the closure alive while only a copy-safe ID crosses taskpools.
  acquire(jobRegistryLock)
  try:
    inc nextJobId
    result = nextJobId
    jobRegistry[][result] = job
  finally:
    release(jobRegistryLock)

proc takeJob(jobId: int): SyncJob {.gcsafe, raises: [].} =
  ## Transfer ownership out of the registry exactly once on the worker.
  acquire(jobRegistryLock)
  try:
    result = jobRegistry[].getOrDefault(jobId)
    jobRegistry[].del(jobId)
  finally:
    release(jobRegistryLock)

proc defaultExecutionPolicy*(): ExecutionPolicy =
  ## Keep the existing developer experience while making the decision explicit.
  ExecutionPolicy(allowSynchronousHandlers: true,
    warnOnSynchronousHandlers: true,
    offloadSynchronousHandlers: true)

proc newThreadPoolExecutor*(pollIntervalMs = 1,
                            maxConcurrentJobs = 0): ThreadPoolExecutor =
  ## Polling keeps the event loop responsive while a FlowVar is pending.
  ## Zero is useful for low-latency tests; positive values avoid busy waiting.
  if maxConcurrentJobs < 0:
    raise newException(ValueError, "maxConcurrentJobs must not be negative")
  new(result)
  result.pollIntervalMs = max(0, pollIntervalMs)
  result.maxConcurrentJobs = maxConcurrentJobs
  result.activeJobs = 0
  result.pool = processPool()

proc toSharedBuffer(value: string): SharedBuffer =
  ## Allocate a stable byte copy that can be transferred through a Flowvar.
  result.length = value.len
  if value.len == 0:
    return
  result.data = allocShared0(value.len)
  copyMem(result.data, value[0].addr, value.len)

proc fromSharedBuffer(buffer: SharedBuffer): string =
  ## Take ownership back on the event-loop thread and release shared storage.
  if buffer.length == 0:
    return ""
  result = newString(buffer.length)
  copyMem(result[0].addr, buffer.data, buffer.length)
  deallocShared(buffer.data)

proc encodeHeaders(headers: Table[string, string]): string =
  ## NUL is not legal in an HTTP header name/value, so it is a compact and
  ## allocation-light separator for this private worker transport.
  for key, value in headers:
    result.add(key)
    result.add('\0')
    result.add(value)
    result.add('\0')

proc decodeHeaders(encoded: string, headers: var Table[string, string]) =
  ## Restore headers only after the worker result has returned to the event loop.
  var cursor = 0
  while cursor < encoded.len:
    let keyOffset = encoded[cursor .. ^1].find('\0')
    let keyEnd = if keyOffset < 0: -1 else: cursor + keyOffset
    if keyEnd < 0:
      break
    let valueStart = keyEnd + 1
    let valueOffset = encoded[valueStart .. ^1].find('\0')
    let valueEnd = if valueOffset < 0: -1 else: valueStart + valueOffset
    if valueEnd < 0:
      break
    headers[encoded[cursor ..< keyEnd]] = encoded[valueStart ..< valueEnd]
    cursor = valueEnd + 1

proc runSyncJob(job: SyncJob): SyncJobResult {.gcsafe, raises: [].} =
  ## Keep the worker boundary tiny so dispatcher state never crosses threads.
  try:
    let response = job()
    result.status = response.status.int
    result.body = toSharedBuffer(response.body)
    result.headers = toSharedBuffer(encodeHeaders(response.headers))
  except ValueError as error:
    result.failed = true
    result.errorKind = 1
    result.errorMessage = toSharedBuffer(error.msg)
  except CatchableError as error:
    result.failed = true
    result.errorKind = 2
    result.errorMessage = toSharedBuffer(error.msg)
  except Exception as error:
    ## Preserve the worker boundary even for user-defined Exception types.
    result.failed = true
    result.errorKind = 3
    result.errorMessage = toSharedBuffer(error.msg)

proc runRegisteredJob(jobId: int): SyncJobResult {.gcsafe, raises: [].} =
  ## Taskpools sees only the integer ID, while the synchronized registry keeps
  ## closure capture and GC ownership explicit at the adapter boundary.
  runSyncJob(takeJob(jobId))

proc execute*(executor: ThreadPoolExecutor, job: SyncJob): Future[Response] {.async.} =
  ## Run blocking-capable sync work away from the async event-loop thread.
  if executor.maxConcurrentJobs > 0 and
     executor.activeJobs >= executor.maxConcurrentJobs:
    let overload = newException(FrameworkError,
      "Synchronous executor capacity exhausted")
    overload.status = Http503
    overload.code = "executor_overloaded"
    raise overload
  ## execute is entered on the event-loop thread, so this counter is an
  ## event-loop-owned admission gate rather than a second worker lock.
  inc executor.activeJobs
  let jobId = registerJob(job)
  try:
    let flow = spawn(executor.pool, runRegisteredJob(jobId))
    while not flow.isReady:
      await sleepAsync(executor.pollIntervalMs)
    let outcome = sync(flow)
    if outcome.failed:
      let message = fromSharedBuffer(outcome.errorMessage)
      if outcome.errorKind == 1:
        raise newException(ValueError, message)
      raise newException(CatchableError, message)
    result = newResponse(HttpCode(outcome.status), fromSharedBuffer(outcome.body))
    decodeHeaders(fromSharedBuffer(outcome.headers), result.headers)
  finally:
    dec executor.activeJobs

## Handler execution policy.
##
## Nim's async event loop must never be blocked by accidental synchronous I/O.
## Sync handlers remain explicit in route metadata, and the application
## dispatcher can offload them through the executor contract before awaiting
## their result on the event loop.

import std/[asyncdispatch, httpcore, locks, monotimes, tables, times]
import pkg/taskpools
import ./core

type
  BlockingDetectedHook* = proc (elapsedMs: int) {.gcsafe.}
  BackendCancellationHook* = proc (cancellation: CancellationToken): bool {.gcsafe.}

  ExecutorHooks* = ref object
    ## Keep callback closures in a separately owned object. Taskpool owns
    ## native worker state, so separating GC-managed hooks avoids mixing
    ## closure finalization with the backend object itself.
    onBlockingDetected*: BlockingDetectedHook
    backendCancellation*: BackendCancellationHook

  ExecutionPolicy* = object
    ## `allowSynchronousHandlers` is permissive for local development; a
    ## production application can set it false and fail during dispatch.
    allowSynchronousHandlers*: bool
    warnOnSynchronousHandlers*: bool
    offloadSynchronousHandlers*: bool
    ## Zero disables the diagnostic. A positive value reports a worker that
    ## has not completed within the configured budget.
    blockingDetectionMs*: int
    ## Zero disables the backend cancellation hook. The core always publishes
    ## the request token first; a concrete executor may add a safe backend
    ## cancellation implementation through the hook.
    forceCancellationAfterMs*: int
    ## A bounded wait absorbs short bursts without allowing an unbounded queue.
    ## Zero preserves immediate overload rejection.
    queueWaitMs*: int

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

  JobBox = ref object
    ## The taskpool receives only a raw pointer. This GC-managed box keeps
    ## the closure alive while it is temporarily outside the GC scan.
    job: SyncJob

  JobSlot = object
    ## Raw registry slots must not contain GC-managed seq/ref state.
    id: int
    box: pointer

  JobRegistryState = object
    slots: ptr UncheckedArray[JobSlot]
    capacity: int
    lock: Lock

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
    blockingDetectionMs*: int
    forceCancellationAfterMs*: int
    queueWaitMs*: int
    hooks*: ExecutorHooks

var sharedPool: Taskpool
var jobRegistry: ptr JobRegistryState
var nextJobId = 0

proc processPool(): Taskpool =
  ## Lazily initialize one backend on the event-loop/root thread. Taskpools
  ## associates spawned work with the calling thread's worker context, so a
  ## single shared pool is safer than constructing one inside every Application.
  if jobRegistry.isNil:
    ## A fixed raw slot table avoids placing Nim's GC-managed Table/seq state
    ## in shared memory. The process owns this registry until exit.
    jobRegistry = cast[ptr JobRegistryState](
      allocShared0(sizeof(JobRegistryState)))
    jobRegistry.capacity = 4096
    jobRegistry.slots = cast[ptr UncheckedArray[JobSlot]](
      allocShared0(sizeof(JobSlot) * jobRegistry.capacity))
    initLock(jobRegistry.lock)
  if sharedPool.isNil:
    sharedPool = Taskpool.new()
  sharedPool

proc registerJob(job: SyncJob): int =
  ## Keep the closure alive while only a copy-safe ID crosses taskpools.
  inc nextJobId
  result = nextJobId
  let box = JobBox(job: job)
  ## The event-loop owner releases this root only after the Flowvar is done.
  GC_ref(box)
  acquire(jobRegistry.lock)
  try:
    for index in 0 ..< jobRegistry.capacity:
      if jobRegistry.slots[index].id == 0:
        jobRegistry.slots[index].id = result
        jobRegistry.slots[index].box = cast[pointer](box)
        return
    GC_unref(box)
    raise newException(ResourceExhaustedError,
      "Synchronous executor job registry is full")
  finally:
    release(jobRegistry.lock)

proc takeJob(jobId: int): JobBox {.gcsafe, raises: [].} =
  ## Read the pointer while the raw registry lock is held. The slot remains
  ## occupied until the event-loop has consumed the Flowvar result.
  var raw: pointer
  acquire(jobRegistry.lock)
  for index in 0 ..< jobRegistry.capacity:
    if jobRegistry.slots[index].id == jobId:
      raw = jobRegistry.slots[index].box
      break
  release(jobRegistry.lock)
  if raw != nil:
    result = cast[JobBox](raw)

proc releaseJob(jobId: int) =
  ## Release the explicit GC root on the event-loop thread after the worker
  ## result has crossed back through the Flowvar.
  var raw: pointer
  acquire(jobRegistry.lock)
  try:
    for index in 0 ..< jobRegistry.capacity:
      if jobRegistry.slots[index].id == jobId:
        raw = jobRegistry.slots[index].box
        jobRegistry.slots[index].id = 0
        jobRegistry.slots[index].box = nil
        break
  finally:
    release(jobRegistry.lock)
  if raw != nil:
    GC_unref(cast[JobBox](raw))

proc defaultExecutionPolicy*(): ExecutionPolicy =
  ## Keep the existing developer experience while making the decision explicit.
  ExecutionPolicy(allowSynchronousHandlers: true,
    warnOnSynchronousHandlers: true,
    offloadSynchronousHandlers: true,
    blockingDetectionMs: 0,
    forceCancellationAfterMs: 0,
    queueWaitMs: 0)

proc newThreadPoolExecutor*(pollIntervalMs = 1,
                            maxConcurrentJobs = 0,
                            blockingDetectionMs = 0,
                            forceCancellationAfterMs = 0,
                            queueWaitMs = 0,
                            onBlockingDetected: BlockingDetectedHook = nil,
                            backendCancellation: BackendCancellationHook = nil): ThreadPoolExecutor =
  ## Polling keeps the event loop responsive while a FlowVar is pending.
  ## Zero is useful for low-latency tests; positive values avoid busy waiting.
  if maxConcurrentJobs < 0:
    raise newException(ValueError, "maxConcurrentJobs must not be negative")
  if blockingDetectionMs < 0:
    raise newException(ValueError, "blockingDetectionMs must not be negative")
  if forceCancellationAfterMs < 0:
    raise newException(ValueError, "forceCancellationAfterMs must not be negative")
  if queueWaitMs < 0:
    raise newException(ValueError, "queueWaitMs must not be negative")
  new(result)
  result.pollIntervalMs = max(0, pollIntervalMs)
  result.maxConcurrentJobs = maxConcurrentJobs
  result.blockingDetectionMs = blockingDetectionMs
  result.forceCancellationAfterMs = forceCancellationAfterMs
  result.queueWaitMs = queueWaitMs
  new(result.hooks)
  result.hooks.onBlockingDetected = onBlockingDetected
  result.hooks.backendCancellation = backendCancellation
  result.activeJobs = 0
  ## Do not initialize native worker threads while an Application is merely
  ## being configured. The event-loop execute path initializes the backend
  ## once, which keeps construction side-effect free and simplifies GC/close
  ## ownership for short-lived test and CLI applications.
  result.pool = nil

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
  ## Taskpools sees only the integer ID, while the registry keeps closure
  ## capture and GC ownership explicit at the adapter boundary.
  let box = takeJob(jobId)
  if box == nil:
    result.failed = true
    result.errorKind = 3
    result.errorMessage = toSharedBuffer("Synchronous executor job missing")
    return
  try:
    result = runSyncJob(box.job)
  finally:
    ## The registry root remains until releaseJob runs on the event loop.
    discard box

proc execute*(executor: ThreadPoolExecutor, job: SyncJob,
              cancellation: CancellationToken = nil): Future[Response] {.async.} =
  ## Run blocking-capable sync work away from the async event-loop thread.
  if executor.pool.isNil:
    executor.pool = processPool()
  if executor.maxConcurrentJobs > 0:
    let admissionStarted = getMonoTime()
    while executor.activeJobs >= executor.maxConcurrentJobs:
      let waitedMs = (getMonoTime() - admissionStarted).inMilliseconds
      if executor.queueWaitMs <= 0 or waitedMs >= executor.queueWaitMs:
        let overload = newException(FrameworkError,
          if executor.queueWaitMs > 0:
            "Synchronous executor queue wait exhausted"
          else:
            "Synchronous executor capacity exhausted")
        overload.status = Http503
        overload.code = if executor.queueWaitMs > 0:
          "executor_queue_timeout" else: "executor_overloaded"
        raise overload
      await sleepAsync(min(executor.pollIntervalMs,
        max(1, executor.queueWaitMs - waitedMs).int))
  ## execute is entered on the event-loop thread, so this counter is an
  ## event-loop-owned admission gate rather than a second worker lock.
  inc executor.activeJobs
  let jobId = registerJob(job)
  try:
    let flow = spawn(executor.pool, runRegisteredJob(jobId))
    let startedAt = getMonoTime()
    var blockingReported = false
    var cancellationRequested = false
    while not flow.isReady:
      let elapsedMs = (getMonoTime() - startedAt).inMilliseconds
      if executor.blockingDetectionMs > 0 and
         not blockingReported and elapsedMs >= executor.blockingDetectionMs:
        blockingReported = true
        ## Detection is deliberately observable but does not interrupt user
        ## code. This keeps diagnostics from changing handler semantics.
        if executor.hooks != nil and executor.hooks.onBlockingDetected != nil:
          executor.hooks.onBlockingDetected(elapsedMs)
      if executor.forceCancellationAfterMs > 0 and
         not cancellationRequested and
         elapsedMs >= executor.forceCancellationAfterMs:
        cancellationRequested = true
        ## Nim cannot safely kill an arbitrary native thread. Publish the
        ## atomic token first, then let an executor-specific hook perform a
        ## stronger cancellation only when its backend guarantees safety.
        if cancellation != nil:
          cancellation.cancel()
        if executor.hooks != nil and executor.hooks.backendCancellation != nil:
          discard executor.hooks.backendCancellation(cancellation)
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
    releaseJob(jobId)
    dec executor.activeJobs

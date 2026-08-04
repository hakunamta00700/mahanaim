## Handler execution policy.
##
## Nim's async event loop must never be blocked by accidental synchronous I/O.
## Sync handlers remain explicit in route metadata, and the application
## dispatcher can offload them through the executor contract before awaiting
## their result on the event loop.

import std/[asyncdispatch, concurrency/threadpool]
import ./core

type
  ExecutionPolicy* = object
    ## `allowSynchronousHandlers` is permissive for local development; a
    ## production application can set it false and fail during dispatch.
    allowSynchronousHandlers*: bool
    warnOnSynchronousHandlers*: bool
    offloadSynchronousHandlers*: bool

  SyncJob* = proc (): Response {.gcsafe.}

  SyncJobResult = object
    ## Thread-pool workers cannot safely throw through a FlowVar. Encode the
    ## failure and recreate it on the event-loop side instead.
    response: Response
    failed: bool
    errorKind: string
    errorMessage: string

  ThreadPoolExecutor* = ref object
    ## The executor owns scheduling policy; Nim manages the process-wide
    ## worker pool so an application does not leak threads during shutdown.
    pollIntervalMs*: int

proc defaultExecutionPolicy*(): ExecutionPolicy =
  ## Keep the existing developer experience while making the decision explicit.
  ExecutionPolicy(allowSynchronousHandlers: true,
    warnOnSynchronousHandlers: true,
    offloadSynchronousHandlers: true)

proc newThreadPoolExecutor*(pollIntervalMs = 1): ThreadPoolExecutor =
  ## Polling keeps the event loop responsive while a FlowVar is pending.
  ## Zero is useful for low-latency tests; positive values avoid busy waiting.
  new(result)
  result.pollIntervalMs = max(0, pollIntervalMs)

proc runSyncJob(job: SyncJob): SyncJobResult {.gcsafe.} =
  ## Keep the worker boundary tiny so dispatcher state never crosses threads.
  try:
    result.response = job()
  except ValueError as error:
    result.failed = true
    result.errorKind = "ValueError"
    result.errorMessage = error.msg
  except CatchableError as error:
    result.failed = true
    result.errorKind = "CatchableError"
    result.errorMessage = error.msg

proc execute*(executor: ThreadPoolExecutor, job: SyncJob): Future[Response] {.async.} =
  ## Run blocking-capable sync work away from the async event-loop thread.
  let flow = spawn runSyncJob(job)
  while not flow.isReady:
    await sleepAsync(executor.pollIntervalMs)
  let outcome = ^flow
  if outcome.failed:
    if outcome.errorKind == "ValueError":
      raise newException(ValueError, outcome.errorMessage)
    raise newException(CatchableError, outcome.errorMessage)
  return outcome.response

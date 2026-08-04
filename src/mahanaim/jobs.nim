## Background job abstraction built on the existing executor boundary.
##
## Jobs never run on the event loop. Retry is bounded and asynchronous, while
## persistence/idempotency remains an explicit responsibility of a durable
## queue adapter and the job author.

import std/[asyncdispatch, httpcore]
import ./core
import ./execution

type
  BackgroundJob* = proc () {.gcsafe.}

  JobRetryPolicy* = object
    maxAttempts*: int
    delayMs*: int

  BackgroundJobResult* = object
    succeeded*: bool
    attempts*: int
    error*: string

  BackgroundJobQueue* = ref object
    executor*: ThreadPoolExecutor
    retryPolicy*: JobRetryPolicy

proc defaultJobRetryPolicy*(): JobRetryPolicy =
  ## One attempt avoids surprising duplicate side effects by default.
  JobRetryPolicy(maxAttempts: 1, delayMs: 0)

proc newBackgroundJobQueue*(executor: ThreadPoolExecutor,
                            retryPolicy = defaultJobRetryPolicy()): BackgroundJobQueue =
  if executor.isNil:
    raise newException(ValueError, "Background job queue requires an executor")
  if retryPolicy.maxAttempts < 1 or retryPolicy.delayMs < 0:
    raise newException(ValueError, "Invalid background job retry policy")
  BackgroundJobQueue(executor: executor, retryPolicy: retryPolicy)

proc enqueue*(queue: BackgroundJobQueue,
              job: BackgroundJob): Future[BackgroundJobResult] {.async.} =
  ## Each attempt uses the same sync executor and therefore cannot block I/O.
  if queue.isNil or queue.executor.isNil or job.isNil:
    raise newException(ValueError, "Background job queue and job are required")
  var lastError = ""
  for attempt in 1 .. queue.retryPolicy.maxAttempts:
    result.attempts = attempt
    try:
      discard await queue.executor.execute(proc(): Response {.gcsafe.} =
        job()
        newResponse(Http204))
      result.succeeded = true
      result.error = ""
      return
    except CatchableError as error:
      lastError = error.msg
      if attempt < queue.retryPolicy.maxAttempts and queue.retryPolicy.delayMs > 0:
        await sleepAsync(queue.retryPolicy.delayMs)
  result.succeeded = false
  result.error = lastError

## Background job abstraction built on the existing executor boundary.
##
## Jobs never run on the event loop. Retry is bounded and asynchronous, while
## persistence/idempotency remains an explicit responsibility of a durable
## queue adapter and the job author.

import std/[asyncdispatch, httpcore, strutils]
import ./core
import ./execution
import ./idempotency

type
  BackgroundJob* = proc () {.gcsafe.}

  JobRetryPolicy* = object
    maxAttempts*: int
    delayMs*: int

  BackgroundJobResult* = object
    succeeded*: bool
    attempts*: int
    error*: string
    deduplicated*: bool

  BackgroundJobQueue* = ref object
    executor*: ThreadPoolExecutor
    retryPolicy*: JobRetryPolicy
    idempotencyStore*: IdempotencyStore

  ScheduledJob* = object
    id*: string
    runAt*: int64
    intervalSeconds*: int64
    job*: BackgroundJob

  JobScheduler* = ref object
    ## Callers pass time to `runDueAt`, keeping clock ownership and test
    ## determinism explicit rather than hiding a timer thread in the framework.
    queue*: BackgroundJobQueue
    scheduled: seq[ScheduledJob]

proc defaultJobRetryPolicy*(): JobRetryPolicy =
  ## One attempt avoids surprising duplicate side effects by default.
  JobRetryPolicy(maxAttempts: 1, delayMs: 0)

proc newBackgroundJobQueue*(executor: ThreadPoolExecutor,
                            retryPolicy = defaultJobRetryPolicy(),
                            idempotencyStore: IdempotencyStore = nil): BackgroundJobQueue =
  if executor.isNil:
    raise newException(ValueError, "Background job queue requires an executor")
  if retryPolicy.maxAttempts < 1 or retryPolicy.delayMs < 0:
    raise newException(ValueError, "Invalid background job retry policy")
  BackgroundJobQueue(executor: executor, retryPolicy: retryPolicy,
    idempotencyStore: idempotencyStore)

proc enqueueInternal(queue: BackgroundJobQueue, key: string,
                     job: BackgroundJob): Future[BackgroundJobResult] {.async.} =
  ## Each attempt uses the same sync executor and therefore cannot block I/O.
  if queue.isNil or queue.executor.isNil or job.isNil:
    raise newException(ValueError, "Background job queue and job are required")
  if key.len > 0:
    if queue.idempotencyStore.isNil:
      raise newException(ValueError,
        "Idempotency store is required for keyed background jobs")
    if not queue.idempotencyStore.claim(key):
      result.succeeded = true
      result.deduplicated = true
      return
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
  if key.len > 0:
    queue.idempotencyStore.release(key)

proc enqueue*(queue: BackgroundJobQueue,
              job: BackgroundJob): Future[BackgroundJobResult] {.async.} =
  ## Unkeyed enqueue preserves the original at-least-once retry contract.
  return await queue.enqueueInternal("", job)

proc enqueueIdempotent*(queue: BackgroundJobQueue, key: string,
                        job: BackgroundJob): Future[BackgroundJobResult] {.async.} =
  ## A successful claim remains stored after completion; failed attempts release
  ## it so a caller can retry the same logical work deliberately.
  if key.strip().len == 0:
    raise newException(ValueError, "Idempotency key is required")
  return await queue.enqueueInternal(key, job)

proc newJobScheduler*(queue: BackgroundJobQueue): JobScheduler =
  if queue.isNil:
    raise newException(ValueError, "Job scheduler requires a queue")
  JobScheduler(queue: queue, scheduled: @[])

proc scheduleAt*(scheduler: JobScheduler, id: string, runAt: int64,
                 job: BackgroundJob) =
  if scheduler.isNil or id.strip().len == 0 or runAt < 0 or job.isNil:
    raise newException(ValueError, "Scheduled job requires id, non-negative time, and job")
  for existing in scheduler.scheduled:
    if existing.id == id:
      raise newException(ValueError, "Duplicate scheduled job: " & id)
  scheduler.scheduled.add(ScheduledJob(id: id, runAt: runAt,
    intervalSeconds: 0, job: job))

proc scheduleEvery*(scheduler: JobScheduler, id: string, firstRunAt,
                    intervalSeconds: int64, job: BackgroundJob) =
  if intervalSeconds <= 0:
    raise newException(ValueError, "Recurring scheduled job requires a positive interval")
  scheduler.scheduleAt(id, firstRunAt, job)
  scheduler.scheduled[^1].intervalSeconds = intervalSeconds

proc runDueAt*(scheduler: JobScheduler, now: int64):
    Future[seq[BackgroundJobResult]] {.async.} =
  if scheduler.isNil or now < 0:
    raise newException(ValueError, "Job scheduler and non-negative time are required")
  var pending: seq[ScheduledJob] = @[]
  for scheduled in scheduler.scheduled:
    if scheduled.runAt <= now:
      result.add(await scheduler.queue.enqueue(scheduled.job))
      if scheduled.intervalSeconds > 0:
        var recurring = scheduled
        ## Advance past a long downtime without replaying every missed period;
        ## applications can choose a catch-up policy explicitly if required.
        let elapsed = now - recurring.runAt
        recurring.runAt += (elapsed div recurring.intervalSeconds + 1) *
          recurring.intervalSeconds
        pending.add(recurring)
    else:
      pending.add(scheduled)
  scheduler.scheduled = pending

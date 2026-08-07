# Errors, lifecycle, timeout, and cancellation

**Audience:** application authors defining failure policy and resource lifetime.
**Verified with:** `nimble test`

Set a single application error policy before startup with `onError`. The default
returns a `FrameworkError` message at its declared status and returns a generic
500 for every other exception, so accidental exception text is not exposed.

```nim
import std/[asyncdispatch, httpcore]
import mahanaim

let app = newApplication()
app.onError(proc (request: Request, error: ref CatchableError): Future[Response]
    {.async, gcsafe.} =
  discard request
  return problemResponse(Http500, "Internal server error", "Try again later"))
```

Raise `FrameworkError` only for intended client-facing failures, and set its
`status` and stable `code`. Treat all other caught errors as internal. Do not
log passwords, authorization headers, cookies, full bodies, or secret values.

## Startup and shutdown

`app.onStartup` and `app.onShutdown` register hooks that execute once in
registration order. Routes, middleware, plugins, error handlers, and hooks are
immutable once startup begins. Put connection setup, consumer registration, and
dependency checks in startup; put flushing and connection cleanup in shutdown.

## Timeouts and synchronous work

`AppConfig.requestTimeoutMs` controls the request deadline. On timeout the
framework cancels `request.cancellation` cooperatively and returns
`504 request_timeout` through the error policy. Nim cannot safely kill a
running async procedure or native thread, so long-running handlers must check
`request.isCancelled()` at safe boundaries and release their own work.

Explicit synchronous routes use the executor according to `ExecutionPolicy`.
When the executor is full, the framework returns `503 executor_overloaded`; if
`queueWaitMs` expires, it returns `503 executor_queue_timeout`. Keep CPU-bound
or blocking work bounded, observable, and idempotent. The operations guide
contains deployment-oriented timeout and recovery guidance.

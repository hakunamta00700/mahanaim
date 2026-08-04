## Small, dependency-free observability boundary.
##
## The core emits structured request events and exposes health/readiness data;
## applications can forward events to Logue, OpenTelemetry, or another sink
## without coupling request dispatch to a logging implementation.

import std/[asyncdispatch, httpcore, json, strutils, tables]
import ./core

type
  RequestEvent* = object
    ## Structured fields avoid forcing consumers to parse human log strings.
    requestId*: string
    httpMethod*: string
    path*: string
    status*: int

  RequestEventSink* = proc (event: RequestEvent) {.gcsafe.}

  Observability* = ref object
    ## Counters are updated on the event loop, so they remain deterministic and
    ## do not introduce a second synchronization dependency into the core.
    requestCount*: int
    errorCount*: int
    inFlight*: int
    nextRequestId*: int
    ready*: bool
    sink*: RequestEventSink

proc newObservability*(sink: RequestEventSink = nil): Observability =
  ## A fresh app gets isolated counters and request-id state.
  Observability(requestCount: 0, errorCount: 0, inFlight: 0,
    nextRequestId: 0, ready: false, sink: sink)

proc validRequestId(value: string): bool =
  ## Accept only a bounded header-safe token; never reflect arbitrary input.
  if value.len == 0 or value.len > 128:
    return false
  for character in value:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':'}:
      return false
  true

proc assignRequestId(observability: Observability,
                     request: var Request): string =
  let supplied = if request.headers.hasKey("x-request-id"):
                   request.headers["x-request-id"] else: ""
  if validRequestId(supplied):
    result = supplied
  else:
    inc observability.nextRequestId
    result = "mahanaim-" & $observability.nextRequestId
  request.headers["x-request-id"] = result

proc observabilityMiddleware*(observability: Observability): Middleware =
  ## One middleware owns correlation, counters, response decoration, and sink
  ## delivery so handlers do not repeat operational bookkeeping.
  if observability.isNil:
    raise newException(ValueError, "Observability instance cannot be nil")
  result = proc(request: Request, next: Handler): Future[Response]
      {.async, gcsafe.} =
    var trackedRequest = request
    let requestId = assignRequestId(observability, trackedRequest)
    inc observability.requestCount
    inc observability.inFlight
    try:
      var response = await next(trackedRequest)
      response.headers["x-request-id"] = requestId
      if response.status.int >= 500:
        inc observability.errorCount
      if not observability.sink.isNil:
        observability.sink(RequestEvent(requestId: requestId,
          httpMethod: trackedRequest.httpMethod, path: trackedRequest.path,
          status: response.status.int))
      return response
    finally:
      dec observability.inFlight

proc setReady*(observability: Observability, ready: bool) =
  ## Readiness follows lifecycle ownership and is false before startup/after stop.
  if observability.isNil:
    return
  observability.ready = ready

proc healthResponse*(observability: Observability): Response =
  ## Liveness reports process reachability and deliberately ignores readiness.
  var document = %*{"status": "ok"}
  document["requests"] = newJInt(observability.requestCount)
  document["errors"] = newJInt(observability.errorCount)
  document["inFlight"] = newJInt(observability.inFlight)
  result = jsonResponse($document)

proc readinessResponse*(observability: Observability): Response =
  ## Readiness is a separate endpoint contract for load balancers and deploys.
  let ready = not observability.isNil and observability.ready
  var document = %*{"status": if ready: "ready" else: "not_ready"}
  result = jsonResponse($document, if ready: Http200 else: Http503)

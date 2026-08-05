## Small, dependency-free observability boundary.
##
## The core emits structured request events and exposes health/readiness data;
## applications can forward events to Logue, OpenTelemetry, or another sink
## without coupling request dispatch to a logging implementation.

import std/[asyncdispatch, httpcore, json, options, strutils, tables]
import ./core
import ./tracing

type
  RequestEvent* = object
    ## Structured fields avoid forcing consumers to parse human log strings.
    requestId*: string
    httpMethod*: string
    path*: string
    status*: int
    traceId*: string
    spanId*: string

  RequestEventSink* = proc (event: RequestEvent) {.gcsafe.}
  StructuredLogSink* = proc (record: JsonNode) {.gcsafe.}
  MetricsProvider* = proc (): string {.gcsafe.}

  Observability* = ref object
    ## Counters are updated on the event loop, so they remain deterministic and
    ## do not introduce a second synchronization dependency into the core.
    requestCount*: int
    errorCount*: int
    inFlight*: int
    nextRequestId*: int
    ready*: bool
    sink*: RequestEventSink
    logSink*: StructuredLogSink
    ## Adapter metrics are registered as providers rather than imported here.
    ## This lets Redis/database/queue modules expose counters without making
    ## the framework observability core depend on every optional backend.
    metricsProviders*: seq[MetricsProvider]
    ## Secret values are copied into the observability boundary at application
    ## construction. This avoids importing configuration into the logger and
    ## guarantees that every structured record is sanitized before delivery.
    redactedSecrets*: seq[string]

proc newObservability*(sink: RequestEventSink = nil,
                       logSink: StructuredLogSink = nil,
                       redactedSecrets: seq[string] = @[]): Observability =
  ## A fresh app gets isolated counters and request-id state.
  Observability(requestCount: 0, errorCount: 0, inFlight: 0,
    nextRequestId: 0, ready: false, sink: sink, logSink: logSink,
    redactedSecrets: redactedSecrets, metricsProviders: @[])

proc registerMetricsProvider*(observability: Observability,
                              provider: MetricsProvider) =
  ## Registration is application-owned and intentionally explicit. A nil
  ## provider would otherwise fail only when the metrics endpoint is scraped.
  if observability.isNil:
    raise newException(ValueError, "Observability instance is required")
  if provider.isNil:
    raise newException(ValueError, "Metrics provider must not be nil")
  observability.metricsProviders.add(provider)

proc redactLogText(value: string, secrets: openArray[string]): string =
  ## Redact literal configured values without interpreting them as patterns.
  ## Empty values are ignored so a missing secret cannot erase every log field.
  result = value
  for secret in secrets:
    if secret.len > 0:
      result = result.replace(secret, "[REDACTED]")

proc sanitizeLogRecord(value: JsonNode,
                       secrets: openArray[string]): JsonNode =
  ## Walk the complete JSON tree rather than relying on today's fixed event
  ## fields. Future structured fields therefore inherit the same safety rule.
  if value.isNil or secrets.len == 0:
    return value
  case value.kind
  of JObject:
    result = newJObject()
    for key, child in value.pairs:
      result[key] = sanitizeLogRecord(child, secrets)
  of JArray:
    result = newJArray()
    for child in value.items:
      result.add(sanitizeLogRecord(child, secrets))
  of JString:
    result = newJString(redactLogText(value.getStr(), secrets))
  else:
    ## Numbers, booleans, and null carry no configured textual secret. Reusing
    ## their immutable node keeps the sanitizer allocation-conscious.
    result = value

proc emitStructuredLog(observability: Observability, record: JsonNode) =
  ## Keep sink delivery behind one boundary so callers cannot accidentally
  ## bypass redaction when new event producers are added.
  if observability.isNil or observability.logSink.isNil:
    return
  observability.logSink(sanitizeLogRecord(record, observability.redactedSecrets))

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

proc assignTraceContext(observability: Observability,
                        request: var Request) =
  ## Continue a valid upstream trace; otherwise start a deterministic root.
  let supplied = request.headers.getOrDefault("traceparent")
  if supplied.len > 0:
    let parsed = parseTraceParent(supplied)
    if parsed.isSome:
      request.trace = parsed.get()
      return
  inc observability.nextRequestId
  request.trace = traceContextForSequence(observability.nextRequestId)
  request.headers["traceparent"] = request.trace.traceParentHeader()

proc requestEventJson*(event: RequestEvent): JsonNode =
  ## Emit stable JSON keys so log collectors can index without parsing text.
  %*{"event": "http.request", "requestId": event.requestId,
     "traceId": event.traceId, "spanId": event.spanId,
     "method": event.httpMethod, "path": event.path, "status": event.status}

proc observabilityMiddleware*(observability: Observability): Middleware =
  ## One middleware owns correlation, counters, response decoration, and sink
  ## delivery so handlers do not repeat operational bookkeeping.
  if observability.isNil:
    raise newException(ValueError, "Observability instance cannot be nil")
  result = proc(request: Request, next: Handler): Future[Response]
      {.async, gcsafe.} =
    var trackedRequest = request
    let requestId = assignRequestId(observability, trackedRequest)
    assignTraceContext(observability, trackedRequest)
    inc observability.requestCount
    inc observability.inFlight
    try:
      var response = await next(trackedRequest)
      response.headers["x-request-id"] = requestId
      response.headers["traceparent"] = trackedRequest.trace.traceParentHeader()
      if response.status.int >= 500:
        inc observability.errorCount
      let event = RequestEvent(requestId: requestId,
        httpMethod: trackedRequest.httpMethod, path: trackedRequest.path,
        status: response.status.int, traceId: trackedRequest.trace.traceId,
        spanId: trackedRequest.trace.spanId)
      if not observability.sink.isNil:
        observability.sink(event)
      emitStructuredLog(observability, requestEventJson(event))
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

const prometheusContentType* = "text/plain; version=0.0.4; charset=utf-8"

proc validPrometheusPrefix(prefix: string): bool =
  ## Metric names are a public boundary: reject arbitrary input instead of
  ## allowing a caller-controlled prefix to inject labels or new samples.
  if prefix.len == 0 or
      prefix[0] notin {'a'..'z', 'A'..'Z', '_', ':'}:
    return false
  for character in prefix:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_', ':'}:
      return false
  true

proc prometheusMetrics*(observability: Observability,
                        namespace = "mahanaim"): string =
  ## Export only framework-owned aggregate gauges/counters. The text format is
  ## intentionally dependency-free; a host can expose this string through an
  ## HTTP route or translate the same values to Logue/OpenTelemetry metrics.
  if observability.isNil:
    raise newException(ValueError, "Observability instance is required")
  let prefix = namespace.strip()
  if not validPrometheusPrefix(prefix):
    raise newException(ValueError, "Prometheus namespace is not a valid metric prefix")
  let ready = if observability.ready: 1 else: 0
  result = "# HELP " & prefix & "_requests_total Total HTTP requests.\n" &
    "# TYPE " & prefix & "_requests_total counter\n" &
    prefix & "_requests_total " & $observability.requestCount & "\n" &
    "# HELP " & prefix & "_errors_total Total HTTP responses with status 500 or greater.\n" &
    "# TYPE " & prefix & "_errors_total counter\n" &
    prefix & "_errors_total " & $observability.errorCount & "\n" &
    "# HELP " & prefix & "_requests_in_flight Current requests being processed.\n" &
    "# TYPE " & prefix & "_requests_in_flight gauge\n" &
    prefix & "_requests_in_flight " & $observability.inFlight & "\n" &
    "# HELP " & prefix & "_ready Whether the application is ready to receive traffic.\n" &
    "# TYPE " & prefix & "_ready gauge\n" &
    prefix & "_ready " & $ready & "\n"
  for provider in observability.metricsProviders:
    let customMetrics = provider()
    if customMetrics.len > 0:
      result.add(customMetrics)
      if not customMetrics.endsWith("\n"):
        result.add("\n")

proc metricsResponse*(observability: Observability): Response =
  ## Keep endpoint wiring application-owned while making content type and
  ## exposition semantics identical for every HTTP adapter.
  result = textResponse(prometheusMetrics(observability))
  result.headers["content-type"] = prometheusContentType

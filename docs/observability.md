# Observability

**Audience:** operators integrating health checks, logs, traces, and metrics.
**Verified with:** `nimble test`

The observability middleware assigns or preserves `X-Request-ID`, tracks request,
error, and in-flight counters, and propagates W3C trace context. Record these as
correlation keys, not user identity. Configure redaction before startup and never
add password, token, cookie, authorization, or full payload fields to logs.

Expose application-owned routes for `healthResponse`, `readinessResponse`, and
`metricsResponse`. Health answers process reachability; readiness controls traffic
admission and must become false before draining. Prometheus text metrics contain
aggregate counters/gauges, not request IDs, trace IDs, secrets, cache keys, or
payloads. Attach vendor exporters through the existing sinks.

# Development and observability workflow

Use `newApplication()` and explicit `ApplicationModule` providers in tests.
Tests may override an exported provider before startup; every dispatch creates
and disposes an independent request scope, while task scopes are explicitly
owned by the caller. `TestClient` and `NetworkTestFixture` cover in-process and
loopback HTTP/SSE/WebSocket paths without sharing process-global state.

`Observability` emits request IDs, W3C `traceparent`, structured events, and
redacted structured logs. `metricsResponse` exports vendor-neutral Prometheus
text; external OpenTelemetry/log exporters are application-owned sinks and
must tolerate failure without exposing request bodies or configured secrets.

Generated applications include a route test and run with the same `nimble`
commands as handwritten applications. During development, use a supervisor
that restarts the binary after a successful build; do not reload source inside
an active process because application startup/shutdown owns provider lifetime.
Run a debugger against that supervised child process and preserve normal
request-timeout/cancellation policy.

Benchmarks are correctness gates, not throughput claims:

```text
nimble benchmarkRouter
nimble benchmarkDatabase
nimble benchmarkSerialization
nimble benchmarkTemplates
nimble benchmarkHttp
```

Record compiler version, operating system, command, input size, and result when
comparing runs. Never promote a benchmark number from a different workload or
machine as a framework guarantee.

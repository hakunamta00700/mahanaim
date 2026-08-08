# Development and observability workflow

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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

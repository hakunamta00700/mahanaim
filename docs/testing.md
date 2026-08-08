# Testing

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** maintainers verifying framework and application contracts.
**Verified with:** `nimble test`, `nimble verify`

Use `newTestClient(app)` for in-process route, middleware, error, validation, and
response negotiation tests. Use `NetworkTestClient` only when adapter/network
fixture behavior matters. Make database fixtures explicit and isolate SQLite paths
or adapters per test; assert transaction/connection behavior directly.

Test HTTP errors, form/CSRF failures, file limits, SSE framing, and WebSocket
session/close behavior at the correct layer. External PostgreSQL, Redis/Valkey,
SMTP, S3, and public TLS tests may skip without credentials, but release requires
recorded credentialed CI or staging evidence.

Run `nimble docsCheck`, `nimble docsExamples`, and `nimble publicApiCheck` with
the regular suite to prevent documentation and public API drift.

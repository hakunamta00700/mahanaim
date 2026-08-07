# Testing

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

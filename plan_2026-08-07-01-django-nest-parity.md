# Plan: Close Django and NestJS parity gaps

## Goal
Move Mahanaim from a broad but pre-1.0 feature surface to a production-verifiable
full-stack and API framework by closing the material gaps identified against Django
and NestJS. The result must prioritize reliable supported capabilities over merely
adding public API names.

## Scope

- In: Core framework, first-party adapters, CLI, test tooling, release evidence,
  and documentation required to close the documented feature and maturity gaps.
- In: Explicit package boundaries and acceptance criteria for optional domains that
  should not be forced into the core.
- Out: Source or binary compatibility with Django, NestJS, Python, TypeScript, or
  Node.js; replacing application-owned provider credentials; deploying a real
  production environment without its owner's authority.
- Out: A claim that every third-party Django/npm ecosystem integration becomes a
  Mahanaim core feature.

## Assumptions and constraints

- The baseline is Mahanaim `0.1.0`, with SQLite and PostgreSQL as the current
  first-party database adapters, Prologue/httpx network boundaries, and the
  existing `Application`/plugin contracts.
- Keep the framework low-magic and Nim-native. Prefer explicit contracts and
  adapters over reflection-dependent emulation of Django or NestJS.
- Preserve existing public API behavior; use the documented semantic-versioning
  and deprecation policy for any incompatible change.
- Every adapter that reaches a networked provider needs unit/contract coverage and
  an opt-in live fixture. A local passing test is not production rollout evidence.
- The existing `plan.md` is canonical for work already completed; this file is a
  new, additive delivery plan and must not be used to rewrite its status history.

## Checklist

- [x] Establish a versioned capability matrix and release-readiness evidence policy.
  - Scope: `README.md`, `docs/support-matrix.md`, `docs/support-policy.md`, `docs/api-stability-policy.md`, `docs/definition-of-done.md`, `.github/workflows/ci.yml`.
  - Done when: Each first-party feature is labelled experimental/stable/deprecated, supported Nim/OS/backend versions and live-evidence requirements are machine-checkable, and the README license statement agrees with `mahanaim.nimble`.
  - Evidence: `docs/support-matrix.md` now lists every first-party feature with a maturity label, supported targets, and its CI/live evidence; `tests/test_docs_contract.nim` validates that table and the README/manifest MIT agreement. `support-policy.md` defines promotion evidence and CI generates `release-artifacts.manifest` on Linux, Windows, and macOS.
  - Validation: Extend `tests/test_docs_contract.nim`; run `nimble docsCheck`, `nimble lockCheck`, `nimble verify`, and inspect the generated release-artifact manifest on every CI OS.

- [x] Add an application module/composition boundary above the current DI container.
  - Scope: `src/mahanaim/di.nim`, `src/mahanaim/application.nim`, `src/mahanaim/controllers.nim`, `src/mahanaim/generator.nim`, `src/mahanaim/cli.nim`, plus focused tests.
  - Done when: Modules can declare imports, providers, controllers, routes, lifecycle hooks, and explicit export visibility; startup rejects duplicate/cyclic modules; request/task/application scopes dispose deterministically; generated apps demonstrate the convention without hidden global discovery.
  - Evidence: `ApplicationModule` provides explicit imports, provider/factory declarations, controller and route installers, lifecycle hooks, exports, and guarded provider overrides. Composition validates the complete graph before side effects, rejects duplicate/cyclic modules and non-exported dependencies, and exposes deterministic request/task scope APIs. The generated project creates and installs a named module; its generated app and test compile in the generator contract.
  - Validation: Added module graph, export visibility, override, scope-disposal, controller/route/lifecycle, duplicate/cycle regression coverage; run `nimble test`, `nimble docsExamples`, and `nimble publicApiCheck`.

- [x] Complete the typed API contract and add first-class API versioning.
  - Scope: `src/mahanaim/validation.nim`, `serialization.nim`, `openapi.nim`, `model_macro.nim`, `openapi_client.nim`, router/application modules, CLI, and API contract tests.
  - Done when: Typed handlers derive request/response schemas without a second manual registry, document multiple media types and error envelopes, support explicit URL/header version policy with deprecation metadata, and generate a deterministic TypeScript client for each selected API version.
  - Evidence: `addTypedVersionedDocumentedRoute` derives DTO schemas at compile time and shares the existing validation/problem envelope, multi-media OpenAPI projection, nullable/nested DTO, and cycle tests. `apiVersionUrl` and `apiVersionHeader` select URL or `Accept; version=` contracts, reject incompatible versions with `406`/`Vary`, expose deprecation metadata, and emit deterministic version-filtered OpenAPI and TypeScript clients.
  - Validation: Compile-time typed-route coverage and runtime URL/header version, incompatible `Accept`, nullable/nested DTO, cycle, and generated-client regression tests; run `nimble test`, `nimble verify`, and `nimble docsExamples`.

- [x] Harden database portability, migration workflow, and relational query ergonomics.
  - Scope: `src/mahanaim/database*.nim`, `sqlite_adapter.nim`, `postgres_adapter.nim`, `migration_commands.nim`, `model_schema.nim`, `database_repository.nim`, `docs/storage-and-orm-integration.md`, and database tests.
  - Done when: The documented SQLite/PostgreSQL matrix covers transactions, migrations, schema history/diff, relation loading, raw-SQL escape hatch, and request pool lifecycle; multi-database/read-write routing has either a tested first-party contract or an explicitly unsupported diagnostic; additional backend adapters have a stable extension protocol.
  - Evidence: SQLite/PostgreSQL capability, transaction, schema history/diff, concurrent migration, rollback, and eager/lazy relation contracts are covered by shared and live fixtures. `newRawSqlQuery`/`executeRaw` preserves bound parameters for explicit dialect escape hatches, while `DatabaseRouter` requires configured read/write roles and reports unsupported routing without fallback. Storage/ORM integration documents extension ownership and cross-database transaction limitations.
  - Validation: Migration, relation, raw SQL/routing, and multi-connection regression fixtures; run `nimble test`, `nimble postgresCheck`, `nimble postgresLiveCheck`, and credentialed `nimble postgresLive` in CI.

- [x] Productize the admin, forms, and durable audit trail.
  - Scope: `src/mahanaim/admin.nim`, `forms.nim`, `templates.nim`, `authorization.nim`, `resources.nim`, `account_auth.nim`, and HTML/admin tests.
  - Done when: Admin resources support durable append-only audit storage, relation-aware inline/formset editing, configurable list filters/actions/layouts, safe field-level permissions, and a documented extension API while preserving the existing authorization boundary.
  - Evidence: `SqliteAdminAuditStore` provides a path- or adapter-owned append-only audit trail with snapshot reads and explicit shutdown ownership. `registerAdminInline` binds a named child formset to a parent field, forces parent association server-side, filters protected fields, rejects cross-parent rows, and calls the new atomic mutation contract; database repository stores commit/roll back the batch as one transaction. Existing list/query, bulk-action, custom-layout, authorization and CSRF boundaries remain shared with these routes, and `operations-guide.md` documents both extension APIs.
  - Validation: Add authorization-bypass, CSRF, relation-inline rollback, audit persistence, HTML escaping, list-filter/action, and custom-layout regression tests; run `nimble test` and network smoke tests for browser form flows.

- [x] Add production authentication provider contracts and credential lifecycle controls.
  - Scope: `src/mahanaim/security.nim`, `account_auth.nim`, `password_hashing.nim`, `login_throttling.nim`, configuration/check modules, and security documentation/tests.
  - Done when: Signed bearer tokens evolve into a documented JWT verification/issuance adapter with key rotation; OAuth2/OIDC and external-introspection adapters have explicit callback contracts; session, reset-token, rate-limit, and key-retirement failures fail closed.
  - Evidence: `JwtTokenAuthBackend` issues and verifies HS256 JWTs with key IDs, issuer/audience/time claims, key retirement, and a revocation-store boundary. `IntrospectionAuthBackend` and `verifyOAuthCallback` isolate application-owned provider I/O, reject state mismatch/timeouts, and return no identity on any invalid result. `linkOAuthIdentity` only links a verified provider subject to an explicit enabled local account, never auto-provisions or matches email. Session keyrings, one-time reset consumption, and distributed throttle errors retain their existing fail-closed contracts.
  - Validation: Add tests for expired/not-yet-valid/rotated/revoked tokens, issuer/audience mismatch, provider timeout, account linking, reset replay, and distributed-throttle failure; run `nimble test`, `nimble check`, and provider-specific opt-in contract fixtures.

- [ ] Deliver first-party outbound email and notification adapters.
  - Scope: `src/mahanaim/email.nim`, configuration/plugin modules, `docs/operations-guide.md`, and email tests.
  - Done when: SMTP and provider callback adapters support TLS policy, authenticated delivery, multipart messages, UTF-8/RFC-compliant headers, attachments, bounded retry/outbox handoff, and redacted failure reporting; the in-memory adapter remains test-only.
  - Validation: Add rendering and injection tests for Unicode names, multipart boundaries, attachments, SMTP/provider failures, and retry exhaustion; run unit tests plus an opt-in disposable SMTP wire fixture.

- [ ] Upgrade background work from local execution to an operable queue and scheduler boundary.
  - Scope: `src/mahanaim/jobs.nim`, `durable_jobs.nim`, `execution.nim`, `idempotency.nim`, CLI, checks, operations documentation, and queue tests.
  - Done when: A first-party external queue adapter specifies serialization, acknowledgement, visibility timeout, retry/backoff, dead-letter behavior, graceful drain, and recovery; a scheduler supports one-shot and recurring jobs with timezone-aware execution; unsafe native worker termination remains explicitly unsupported.
  - Validation: Add deterministic fake-clock tests and opt-in live queue tests for duplicate delivery, crash recovery, expiry, dead-letter routing, drain timeout, and scheduler misfire behavior; run `nimble test`, `nimble verify`, and the provider live gate.

- [x] Expand HTTP transport capabilities and deployment behavior.
  - Scope: `src/mahanaim/http_adapter.nim`, `httpx_adapter.nim`, `prologue_server.nim`, `response_policy.nim`, `static_assets.nim`, security/config modules, deployment recipes, and wire tests.
  - Done when: Compression negotiation (gzip/Brotli where the backend permits), conditional/static-file response policy, proxy/timeouts, and graceful shutdown are uniformly applied across supported adapters; unsupported HTTP/2/HTTP/3 capabilities are reported rather than implied.
  - Evidence: `HttpTransportCapabilities` reports the common HTTP/1.1 contract and explicit gzip/Brotli/HTTP/2/HTTP/3 limitations for the stdlib, Prologue, and httpx adapters. Conditional ETag policy, trusted-proxy and request-timeout handling remain application-owned; single static byte ranges and HEAD semantics are finalized centrally, and the operations guide assigns compression/protocol termination to a configured reverse proxy.
  - Validation: Add wire tests for compression, `Vary`, ETag/range/HEAD semantics, slow client/shutdown, proxy forwarding, and adapter capability reports; run `nimble test`, `nimble httpxTest`, `nimble beastLive`, and `nimble httpsLive`.

- [x] Formalize cache, object-storage, and distributed rate-limit provider support.
  - Scope: `src/mahanaim/storage.nim`, `redis_resp.nim`, `security.nim`, plugin/config/check modules, operations documentation, and live tests.
  - Done when: S3-compatible signing/credential/retry policy and Redis/Valkey cache/rate-limit behavior are supplied by versioned adapters, expose metrics, document eviction/failure semantics, and have clear production configuration checks.
  - Evidence: `S3ObjectTransport` keeps endpoint TLS, signing, credential refresh, and provider retry classification application-owned while `newRetryingS3ObjectTransport` enforces a finite operation budget. `RedisCacheStore`, `RedisValkeyRateLimitStore`, and RESP compatibility/stat snapshots provide shared cache/quota behavior, bounded reconnect diagnostics, server-side TTL, and eviction checks. The operations guide documents local-store boundaries, production compatibility probes, redaction, and cache failure semantics.
  - Validation: Add tests for credential expiry, retry budget exhaustion, cache stampede/TTL, Redis disconnect/reconnect, distributed rate-limit consistency, and secret redaction; run `nimble test`, `nimble redisLiveCheck`, and credentialed `nimble redisLive`.

- [ ] Define real-time, event, GraphQL, and microservice extensions as independently releasable packages.
  - Scope: new package design documents and package directories; `channels.nim`, `redis_channel_layer.nim`, WebSocket modules, plugin API, and package-level tests.
  - Done when: The core exposes stable extension points for presence and domain events; separate packages define GraphQL schema/resolver/subscription support and selected transports (at least gRPC plus one broker), with lifecycle, auth, backpressure, serialization, and error contracts. Do not add a transport to core solely for parity.
  - Validation: Add package compile/contract tests, WebSocket event-order/backpressure tests, and opt-in interoperability fixtures for each chosen transport; run core `nimble test` plus each package's test/build gate.

- [ ] Improve observability, testing ergonomics, and developer tooling.
  - Scope: `src/mahanaim/observability.nim`, `testing.nim`, `checks.nim`, CLI/generator modules, benchmarks, docs, and CI.
  - Done when: Test applications can override modules/providers and isolate scoped dependencies; tracing/metrics/logging offer documented exporter adapters and profiling hooks; CLI scaffolds unit/integration/e2e tests and supports a safe development reload/debug workflow; benchmarks publish reproducible, comparable measurements rather than unqualified performance claims.
  - Validation: Add tests for provider overrides, request-scope isolation, trace propagation, exporter failure/redaction, and generated test projects; run `nimble test`, `nimble verify`, all benchmark correctness gates, and CI matrix checks.

- [ ] Specify optional domain packages without expanding the core indiscriminately.
  - Scope: architecture decision records and package skeletons for Geo/GIS, multi-tenancy, CMS/content, full-text search, frontend integration, and real-time presence.
  - Done when: Each domain has a published decision of first-party package, third-party integration guide, or intentionally unsupported status; chosen packages define tenancy/data-isolation and security boundaries before implementation; no optional dependency is added to `mahanaim.nimble` without an approved package contract.
  - Validation: Review the ADRs against `docs/nim-fullstack-framework-requirements.md`; compile each package skeleton independently and run `nimble docsCheck` to ensure status and support matrices agree.

- [ ] Publish adoption documentation and execute the release qualification matrix.
  - Scope: `README.md`, all `docs/` guides, examples, changelog, CI/release workflows, support matrix, and release artifacts.
  - Done when: New users can scaffold an SSR/admin app and a versioned API/service app; upgrade/migration/security/rollback guides are complete; Linux, Windows, and macOS artifacts and each supported live-provider result are recorded; staging TLS, certificate renewal, reconnect, and rollback evidence is attached before marking features stable.
  - Validation: Run `nimble test`, `nimble verify`, `nimble check`, `nimble docsCheck`, `nimble docsExamples`, provider live gates, `git diff --check`, and the full CI/release matrix; manually follow both published quickstarts in clean environments.

## Completion condition

All checklist items are checked, their validation passes, each completed item is
committed with its plan update, and the support matrix labels any remaining
provider or optional-package limitation explicitly.

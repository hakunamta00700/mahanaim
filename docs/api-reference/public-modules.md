# Public module map

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](../index.md) · [지원 매트릭스](../support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](../support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** application and extension authors choosing APIs from `import mahanaim`.
**Stability:** follow the feature maturity in the [support matrix](../support-matrix.md).
**Verification:** `nimble docsCheck` reads `src/mahanaim.nim` and fails when an
exported module has no row in this table. `nimble publicApiCheck` protects the
representative compile contract.

The umbrella package re-exports the modules below. The feature column is the
support-matrix row that owns its maturity and evidence; the guide column is the
canonical user-facing contract. Module-level mapping is deliberately separate
from the detailed API pages: a public symbol must still be described in its
linked guide with its parameters, ownership, failures, and runnable example.

| Public module | Support feature | Canonical guide | Ownership boundary |
| --- | --- | --- | --- |
| `core` | `application-routing` | [Core API](core.md) | Request/response value contracts |
| `router` | `application-routing` | [Routing](../routing.md) | Route matching and URL building |
| `application` | `application-routing` | [Application and modules](../application-and-modules.md) | Lifecycle and dispatch |
| `route_dsl` | `application-routing` | [Routing](../routing.md) | Declarative route registration |
| `config` | `observability-testing-cli` | [Configuration](../configuration.md) | Application-owned configuration |
| `http_adapter` | `http-transport` | [Deployment](../deployment.md) | HTTP transport adapter |
| `generator` | `application-routing` | [Getting started](../getting-started.md) | Project and app scaffolding |
| `security` | `authentication-security` | [Security](../security.md) | Framework policy, application configuration |
| `validation` | `typed-api-openapi` | [Requests and validation](../requests-and-validation.md) | Input parsing and problem responses |
| `response_policy` | `typed-api-openapi` | [Responses and negotiation](../responses-and-negotiation.md) | Representation selection and caching |
| `checks` | `observability-testing-cli` | [Developer workflow](../developer-workflow.md) | Pre-flight application checks |
| `models` | `sqlite-storage` | [Models and metadata](../models-and-metadata.md) | Backend-neutral metadata |
| `serialization` | `typed-api-openapi` | [Serialization](../serialization.md) | Wire representation policy |
| `execution` | `application-routing` | [Errors and lifecycle](../errors-and-lifecycle.md) | Executor capacity and cancellation |
| `prologue_adapter` | `http-transport` | [Deployment](../deployment.md) | Prologue transport boundary |
| `testing` | `observability-testing-cli` | [Testing](../testing.md) | In-process test client and fixtures |
| `body_parser` | `typed-api-openapi` | [Requests and validation](../requests-and-validation.md) | Form and multipart parsing |
| `upload_storage` | `storage-cache-rate-limit` | [Uploads](../uploads.md) | Validated upload persistence |
| `prologue_server` | `http-transport` | [Deployment](../deployment.md) | Prologue listener lifecycle |
| `websocket_adapter` | `realtime-events` | [WebSocket](../websocket.md) | WebSocket adapter boundary |
| `model_macro` | `sqlite-storage` | [Models and metadata](../models-and-metadata.md) | Compile-time metadata declaration |
| `database` | `sqlite-storage` | [Database connections](../database-connections.md) | Database adapter contract |
| `openapi` | `typed-api-openapi` | [OpenAPI](../openapi.md) | Schema collection and artifacts |
| `observability` | `observability-testing-cli` | [Observability](../observability.md) | Logs, metrics, and health contracts |
| `messagepack` | `typed-api-openapi` | [Serialization](../serialization.md) | MessagePack encoder boundary |
| `forms` | `admin-forms` | [Forms](../forms.md) | Form state and CSRF rendering |
| `resources` | `admin-forms` | [Admin](../admin.md) | Metadata CRUD resource convention |
| `di` | `dependency-injection` | [Application and modules](../application-and-modules.md) | Dependency scope ownership |
| `jobs` | `background-jobs` | [Background jobs](../background-jobs.md) | Job scheduling and retries |
| `tracing` | `observability-testing-cli` | [Observability](../observability.md) | Trace context propagation |
| `sqlite_adapter` | `sqlite-storage` | [SQLite CRUD and migration tutorial](../sqlite-crud-migration-tutorial.md) | SQLite connection ownership |
| `database_pool` | `sqlite-storage` | [Database connections](../database-connections.md) | Borrowed connection lifecycle |
| `database_session` | `sqlite-storage` | [Database connections](../database-connections.md) | Transaction and unit-of-work lifecycle |
| `database_repository` | `sqlite-storage` | [Querying](../querying.md) | Repository persistence boundary |
| `redis_resp` | `storage-cache-rate-limit` | [Cache](../cache.md) | Redis/Valkey protocol adapter |
| `templates` | `admin-forms` | [Templates](../templates.md) | Escaped rendering engine |
| `model_schema` | `typed-api-openapi` | [Models and metadata](../models-and-metadata.md) | Input and schema projection |
| `admin` | `admin-forms` | [Admin](../admin.md) | Protected CRUD and audit boundary |
| `query_components` | `typed-api-openapi` | [API development](../api-development.md) | Bounded query controls |
| `aggregate_routes` | `typed-api-openapi` | [API development](../api-development.md) | Aggregate response routes |
| `localization` | `application-routing` | [Responses and negotiation](../responses-and-negotiation.md) | Request locale and formatting |
| `migration_commands` | `sqlite-storage` | [Migrations](../migrations.md) | Migration command boundary |
| `authorization` | `authentication-security` | [Authorization](../authorization.md) | Permission policy evaluation |
| `password_hashing` | `authentication-security` | [Password security](../password-security.md) | Password-hash policy |
| `seed_commands` | `sqlite-storage` | [Migrations](../migrations.md) | Seed command boundary |
| `login_throttling` | `authentication-security` | [Authentication](../authentication.md) | Login-rate limiting |
| `release_checks` | `observability-testing-cli` | [Release guide](../release-guide.md) | Release qualification checks |
| `account_auth` | `authentication-security` | [Authentication](../authentication.md) | Account/session lifecycle |
| `cli` | `observability-testing-cli` | [CLI reference](../cli-reference.md) | Application command registration |
| `idempotency` | `background-jobs` | [Background jobs](../background-jobs.md) | Idempotency claim ownership |
| `durable_jobs` | `background-jobs` | [Background jobs](../background-jobs.md) | Durable job store boundary |
| `static_assets` | `storage-cache-rate-limit` | [Static assets](../static-assets.md) | Asset collection boundary |
| `storage` | `storage-cache-rate-limit` | [Storage](../storage.md) | Object storage adapter contract |
| `flash` | `email-notifications` | [Email and notifications](../email-and-notifications.md) | Session-scoped flash messages |
| `syndication` | `email-notifications` | [Email and notifications](../email-and-notifications.md) | RSS and sitemap rendering |
| `email` | `email-notifications` | [Email and notifications](../email-and-notifications.md) | Message transport boundary |
| `controllers` | `application-routing` | [Routing](../routing.md) | Controller action dispatch |
| `template_adapters` | `admin-forms` | [Server-rendered pages](../server-rendered-pages.md) | Alternate template engine boundary |
| `channels` | `realtime-events` | [Channel layers](../channel-layers.md) | In-memory and callback channel contracts |
| `openapi_client` | `typed-api-openapi` | [OpenAPI](../openapi.md) | Generated TypeScript client artifacts |
| `httpx_adapter` | `http-transport` | [Deployment](../deployment.md) | Direct httpx server adapter |
| `redis_channels` | `realtime-events` | [Channel layers](../channel-layers.md) | Redis pub/sub channel transport |
| `redis_channel_layer` | `realtime-events` | [Channel layers](../channel-layers.md) | Redis ChannelLayer ownership |
| `postgres_adapter` | `postgresql-adapter` | [PostgreSQL](../postgresql.md) | Optional libpq database adapter |
| `postgres_testing` | `postgresql-adapter` | [Testing](../testing.md) | Credentialed PostgreSQL fixture |

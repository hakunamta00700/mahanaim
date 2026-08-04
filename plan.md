# Mahanaim 구현 계획

> 체크박스 규칙: `[x]`는 구현·테스트·문서화까지 완료한 항목이고, `[ ]`는 미완료 또는 진행 중인 항목이다. 부분 완료 항목은 본문에 남은 범위를 기록한다.

### Custom model field foundation

- [x] `newModelCustomField(name, wireType)`로 임의 Nim custom type을 명시적 JSON/wire metadata 경계에 연결한다.
- [x] custom field 선언의 중복·미존재 필드를 model macro 단계에서 거부한다.
- [ ] PostgreSQL live 환경에서 custom field codec과 typed result mapping을 검증한다.

### Template collection rendering

- [x] `TemplateRenderContext`와 명시적 collection 등록 API를 추가하고 `{% for item in collection %}` loop의 중첩·조건문·자동 escaping을 회귀 테스트한다.
- [-] 동적 nested collection projection과 AST-aware `TemplateHelperArgument`/`registerHelper`를 추가해 현재 loop context·named argument·quoted literal을 안전하게 렌더링하고 회귀 테스트했다. 전체 구조형 template AST는 후속 범위로 남긴다.

## 2026-08-04 transaction contract

- [x] DatabaseAdapter transaction guard가 성공 시 commit, 예외 시 rollback을 보장한다.
- [x] backend가 지원하지 않는 savepoint 연산은 명시적으로 실패하도록 계약화했다.
- [x] fake adapter 회귀 테스트와 `nimble test`를 통과했다.
- [-] SQLite driver의 transaction/savepoint/migration up·down history와 PostgreSQL libpq adapter, backend capability/isolation contract를 추가했다. 환경 기반 `postgres_testing` rollback fixture factory, compile gate와 선택적 `postgresLive` contract task를 추가했고 live task에 repository CRUD route·serializable isolation·DDL rollback 검증을 연결했으며, credential이 제공되지 않은 현재 환경에서는 live 실행을 건너뛴다.

## 2026-08-04 executor lifecycle 안정화

- [x] taskpool job registry에서 GC 관리 `Table/seq`를 shared memory에 저장하지 않도록 raw slot registry로 분리한다.
- [x] job closure의 GC root 해제를 event-loop의 Flowvar 완료 이후로 제한한다.
- [x] executor backend를 실제 sync 작업 시점에 lazy 초기화하고 반복 application lifecycle 회귀 테스트를 추가한다.

## 2026-08-04 P0 분산 rate-limit store

- [x] 원자적 remote counter 결과를 표현하는 `RateLimitCounterClient` 계약과 `RedisValkeyRateLimitStore` adapter를 제공한다.
- [x] bounded immediate retry와 backend 오류 fail-closed 503 경로를 회귀 테스트한다.
- [-] Redis/Valkey RESP client, server-side TTL 응답과 loopback live socket fixture를 추가하고 bounded retry·fail-closed 및 장애 후 재연결 회귀 경로를 검증했다. requests/success/failure/connection/reconnect snapshot metrics도 제공하며, 실제 Redis/Valkey compatibility matrix와 eviction 운영 지침은 남아 있다.

상태: 진행 중  
작성일: 2026-08-04  
상세 요구사항: [docs/nim-fullstack-framework-requirements.md](docs/nim-fullstack-framework-requirements.md)  
상세 실행 기록: [docs/nim-fullstack-framework-implementation-plan.md](docs/nim-fullstack-framework-implementation-plan.md)

이 문서는 요구사항을 구현 가능한 단위로 추적하기 위한 상위 체크리스트다. 각 항목은 코드, 테스트, 문서가 함께 완료될 때 `[x]`로 변경한다.

## 우선순위 기준

| 우선순위 | 판단 기준 | 대표 범위 |
|---|---|---|
| P0 | 모든 기능의 기반이거나 보안·정합성을 직접 좌우함 | 공통 요청 모델, 라우터, middleware, lifecycle, 설정, 오류, 테스트 |
| P1 | 첫 번째 실사용 CRUD/API 제품을 완성함 | 모델, migration, DB adapter, serializer, typed API, admin 기초 |
| P2 | 운영 안정성과 확장성을 높임 | observability, rate limit, timeout, background job, plugin/DI |
| P3 | 핵심 경로와 분리 가능한 선택 기능 | 고급 template, WebSocket/SSE 확장, 추가 backend, CLI 확장 |

원칙: P0의 계약과 회귀 테스트를 먼저 고정하고, P1은 P0 API 위에서 구현하며, P2/P3는 안정적인 extension point 뒤에 둔다.

## P0 — 프레임워크 기초와 실행 경로

### 공통 계약

- [x] `Request`, `Response`, `Handler`, `Middleware`, `Route`의 framework-neutral 계약을 고정한다.
- [x] `Application`이 router, middleware, lifecycle, security, error policy를 소유하도록 한다.
- [x] sync handler를 명시적 adapter와 executor 경계로 감싼다.
- [x] 요청 timeout과 cooperative cancellation token을 공통 dispatch 경계에 추가한다.
- [x] deprecated std threadpool을 taskpools backend로 교체하고 GC-managed response를 copy-safe worker buffer로 bridge한다.
- [x] executor 동시 실행 상한과 capacity exhausted 오류 계약을 추가한다.
- [x] executor 동시 실행 상한을 AppConfig와 process environment provider에 연결한다.
- [x] 취소된 sync 작업이 worker에서 user handler에 진입하지 않는 cooperative pre-start cancellation을 추가한다.
- [x] 실행 중 cooperative cancellation 신호를 atomic token으로 전달하고 worker가 안전 지점에서 종료하도록 한다.
- [x] blocking 자동 감지와 atomic cooperative cancellation escalation 정책을 추가한다.
- [-] executor backend cancellation hook, blocking escalation과 cooperative token 경계를 추가했다. taskpools가 임의 native worker 종료를 안전하게 보장하지 않으므로 실제 강제 cancellation adapter는 안전한 backend API가 제공될 때까지 보류한다.

### HTTP와 라우팅

- [x] exact, named parameter, typed parameter, wildcard, route group, named URL을 구현한다.
- [x] method dispatch, 404/405 fallback, middleware composition을 검증한다.
- [x] Prologue request/response adapter와 catch-all server bridge를 제공한다.
- [x] static first-segment prefix index와 dynamic fallback을 추가하고 기존 precedence를 보존한다.
- [x] wildcard URL building 인코딩 정책을 확정하고 예약 문자가 route shape를 바꾸지 않게 한다.
- [x] 내부 route tree matching으로 static/parameter/wildcard 후보를 좁히고 precedence를 보존한다.
- [x] 고정 route cardinality와 반복 횟수의 deterministic router benchmark suite를 추가한다.
- [x] Prologue raw form body와 `Content-Type`을 공통 body parser로 연결하고 contract test를 추가한다.
- [x] multipart upload storage에 filename traversal, size, MIME, extension, overwrite 정책과 web root 분리 검증을 추가한다.
- [x] Prologue upload/WebSocket adapter와 Windows stdlib 종료 가능한 socket-level smoke fixture를 추가한다.

### 입력·출력과 오류

- [x] JSON, form-urlencoded, multipart body parser와 body-scoped validation error를 제공한다.
- [x] HTML/JSON/text representation과 `Accept` 기반 406 응답을 제공한다.
- [x] stream/SSE/WebSocket representation metadata와 core response helper를 추가한다.
- [x] 표준 HTTP adapter에서 SSE representation framing을 TCP wire로 검증한다.
- [x] 표준 TCP adapter의 stream/SSE 응답을 실제 chunked transfer wire로 통합한다.
- [x] 표준 TCP adapter의 WebSocket upgrade와 기본 text/binary/control frame wire를 통합한다.
- [x] 표준 HTTP·Windows Prologue adapter의 단일 response `Accept` negotiation과 406 wire 정책을 통합한다.
- [x] `Accept`로 표현을 선택하는 모든 response policy 결과에 `Vary: Accept`를 추가해 캐시가 다른 표현을 재사용하지 않도록 하고 stream/SSE/WebSocket 협상 회귀를 검증한다.
- [x] 표준 HTTP adapter에서 buffered/stream/SSE representation variant를 `Accept` 기준으로 wire 선택한다.
- [x] Windows Prologue live fixture에서 variant 선택과 WebSocket upgrade `Accept` bypass를 검증한다.
- [x] stdlib와 Beast/httpx native socket을 공통 WebSocket byte transport와 session contract로 연결한다.
- [-] Beast/httpx adapter overload의 Linux compile contract와 stdlib/Beast 공통 WebSocket representation boundary를 추가했다. 실제 Beast live fixture와 socket ownership/shutdown wire 검증은 남아 있다.
- [x] 표준 network adapter의 close 중 serve cancellation을 graceful shutdown으로 정리한다.
- [x] application-level error handler와 problem JSON envelope를 제공한다.

### 부팅 전 정합성 검사

- [x] `checkApplication`이 config·route·model·security·execution과 명시적 migration registry의 이름·경로·SQLite operation을 함께 검사하고 standalone/embedding CLI `check`가 같은 report를 사용한다. Application에 주입된 실제 `SecurityPolicy`를 기본 검사 대상으로 보존해 runtime middleware와 pre-flight 검증이 어긋나지 않도록 했다.

### 설정과 보안

- [x] `.env`, JSON, TOML flat key/value, process environment provider와 precedence를 구현한다.
- [x] secret store, redaction, secure response headers, allowed host, CORS, body size limit을 구현한다.
- [x] signed value/cookie와 CSRF HMAC 계약을 구현한다.
- [x] 앱별 fixed-window rate limit과 429/quota headers 정책을 구현한다.
- [x] 요청 timeout과 cooperative cancellation 정책을 구현한다.
- [x] signed cookie keyring 검증과 legacy key 감지·rotation primitive를 구현한다.
- [x] TOML 전체 문법 파서를 연결하고 AppConfig scalar schema validation을 구현한다.
- [x] signed session cookie와 교체 가능한 `AuthBackend`, HMAC bearer token adapter를 `AuthContext` 및 required authentication route의 401 정책에 연결하고 SessionPolicy primary/legacy secret rotation을 제공한다.
- [x] role/group permission, object-level policy와 route guard를 독립 `AuthorizationPolicy` 모듈로 제공한다.
- [-] algorithm-neutral `PasswordHasher` 계약과 `nimcrypto` PBKDF2-HMAC-SHA256 reference adapter, `argon2` C-backed Argon2id adapter, per-password salt/parameter encoding, work-factor 판단·`verifyAndRehash` rotation, current-password 검증 기반 `changePassword`, stateless signed reset token/expiry 검증, atomic one-time reset token store, 교체 가능한 login throttling hook과 in-memory·distributed counter adapter를 제공한다. adapter-neutral account store와 login/logout/password-change/password-reset request·confirm route flow, 배포 호스트별 Argon2 hash/verify benchmark harness도 추가했으며 bcrypt adapter와 production benchmark 결과 확정은 후속 범위다.
- [-] rate limit·request size·timeout·secure cookie 정책과 HTTPS reverse-proxy 배포 점검표를 `docs/operations-guide.md`에 문서화하고 기존 contract test 범위를 명시했다. 실제 인증서·proxy hop·TLS wire 검증과 `check`의 HTTPS 환경 검사 연동은 후속 범위다.
- [x] 공유 가능한 backend-neutral rate limit store 계약과 메모리 구현을 연결한다.
- [-] Redis/Valkey RESP adapter와 bounded retry, socket timeout, 실패 시 연결 폐기 및 재연결 회귀 검증, 운영용 snapshot metrics를 구현했다. production compatibility와 eviction 운영은 남아 있다.
- [x] executor에 bounded queue wait backpressure 정책을 연결한다.

### Prologue 호환 계층

- [x] Prologue 0.6.8 의존성과 lockfile을 고정한다.
- [x] mocking request 및 mocking context에서 adapter와 lifecycle을 검증한다.
- [x] Prologue form body를 core body parser 계약으로 변환한다.
- [x] Prologue multipart upload API를 core BodyPart/upload storage 계약으로 변환한다.
- [x] WebSocket frame kind와 adapter-owned session callback core 계약을 추가한다.
- [x] Prologue WebSocket API와 Windows native request upgrade adapter를 구현한다.
- [x] Windows stdlib Prologue backend에 adapter-owned transport, ephemeral port, graceful close smoke fixture를 추가한다.
- [x] Windows stdlib Prologue backend의 socket ownership과 종료 가능한 socket-level smoke fixture를 완성한다.
- [x] Windows stdlib backend의 실제 TCP 요청·응답과 graceful shutdown을 fixture로 검증한다.
- [-] Beast/httpx ownership overload를 `beastCheck` compile gate로 검증한다. 실제 Beast backend의 socket ownership과 TCP/WebSocket live fixture는 Linux runner에서 후속 구현한다.

### 개발 품질

- [x] `nimble test`, `nimble verify`, `nimble check`를 CI와 동일하게 실행한다.
- [x] lockfile 기반 dependency 설치와 기본 CI를 구성한다.
- [x] `new` 프로젝트 생성기가 환경 변수 예제, 안전한 `.gitignore`, health route를 가진 앱 모듈과 실제 dispatch 테스트를 생성하도록 확장한다.
- [-] 지원 OS/Nim 2.2.4 matrix에서 test·verify·check·build를 실행하고 OS별 release candidate와 SHA-256 checksum artifact를 생성하도록 CI를 확장했다. 실제 GitHub runner 실행 결과와 추가 지원 버전 확대는 후속 검증 범위다.
- [-] 모든 기능에 적용할 Definition of Done 체크리스트를 [`docs/definition-of-done.md`](docs/definition-of-done.md)에 고정했다. 기존 기능에 대한 항목별 적용과 외부 환경 gate 증거 수집은 진행 중이다.

### 2026-08-04 구현 기록

- [x] TOML provider가 `parsetoml`로 전체 TOML 문법을 읽고, 지원 scalar와 `secrets.*`를 공통 설정 표현으로 flatten한다.
- [x] TOML 배열·날짜·미등록 키를 조용히 버리지 않고 안전한 `ValueError`로 거부한다.
- [x] TOML dependency lock, 설정 회귀 테스트, `nimble build`/`nimble test`를 검증한다.
- [x] AppConfig에 배열·날짜·복합 타입을 보존하는 structured schema mapping을 추가한다.

## P1 — 첫 실사용 풀스택 제품

### 데이터와 모델

- [x] backend-neutral field/index/constraint/relation metadata와 model registry를 제공하고, model macro에서 명시적 index/constraint/relation 선언을 함께 생성한다.
- [x] metadata 기반 JSON serializer와 sensitive/nullable/rename 정책 및 string-backed enum 검증을 제공한다.
- [x] metadata 기반 patch projection과 partial update serializer를 제공한다.
- [x] registry 기반 nested DTO serializer를 제공한다.
- [x] object field에서 backend-neutral metadata를 생성하는 model macro를 제공하고, `Option[T]`를 nullable metadata와 optional input schema로 매핑하며 명시적 index/constraint/relation 선언과 `seq[T]`/`array[N,T]` JSON collection을 추가한다.
- [x] 표준 serialization adapter 확장점과 DateTime·UUID·file metadata 정규화/검증을 제공한다.
- [x] model metadata를 validation/form/OpenAPI 공통 `FieldSpec` schema로 변환하고 float/boolean/JSON 입력 타입, string-backed enum, 교체 가능한 widget registry와 model formset을 연결했다.
- [x] JSON serializer 결과를 결정적 MessagePack binary로 인코딩·복원하고 JSON/MessagePack `Accept` negotiation과 chunked stream response를 제공하며 truncated/trailing payload를 거부한다. DateTime·UUID·enum·file normalization과 명시적 custom `wireType` codec registry를 포함한다.
- [x] SQLite/PostgreSQL에 공통 적용할 parameterized query·migration·transaction adapter 계약을 제공한다.
- [x] transaction guard와 savepoint lifecycle 계약, commit/rollback 회귀 테스트를 제공한다.
- [x] DatabaseSession unit-of-work가 borrowed connection에서 begin/commit/rollback/release를 보장한다.
- [-] SQLite/PostgreSQL query·transaction adapter, 공통 `DatabaseResult`/column metadata contract, SQLite 선언 타입·runtime storage class 및 PostgreSQL type OID 기반 typed scalar result mapping, QuerySet/aggregate compiler와 repository aggregate result mapping, aggregate route adapter, migration history/JOIN compiler, typed row-lock mode, bounded pool, request session의 active isolation 설정, capability matrix와 metadata repository relation execution을 제공했다. PostgreSQL live task에 serializable isolation, repository CRUD route, typed metadata, filtering, grouped aggregate, one-to-many relation, DDL rollback 검증을 연결했고 source compile gate도 추가했다. CI PostgreSQL service에서 이를 실행하며, 현재 환경의 credential 부재로 local live 결과는 아직 확인하지 못했다.

### API와 서버 렌더링

- [x] named field extraction, scalar coercion, validation error aggregation을 제공한다.
- [x] 명시적 input schema에서 OpenAPI 3.1 문서와 제약조건을 생성한다.
- [x] parameterized query contract에 bounded pagination page/size/offset 정책을 연결한다.
- [x] 공통 query component로 pagination/filter/sort/field-selection과 typed cursor filter/token 변환, signed/expiring next cursor metadata, opt-in total metadata, metadata-driven aggregate expression parser, query validation 오류 형식을 제공하고 QuerySet aggregate SQL compiler/repository mapping/route, typed arithmetic annotate projection, eager one-hop/many-to-many through loading과 명시적 lazy relation loader를 추가했다. one-to-many와 many-to-many 모두 parent page 기준 bound `IN` batching을 적용했다.
- [x] Accept quality(`q`) 우선순위와 `q=0` 거부를 포함한 content negotiation을 제공한다.
- [-] explicit typed response schema와 HTML/text/JSON/file/redirect/stream/SSE/WebSocket response helper, HTML·HTMX partial·JSON 선택 helper, 다중 route OpenAPI registry와 operation별 다중 content type, Swagger/ReDoc UI route를 추가하고 `addDocumentedRoute`로 route/schema 동시 등록을 지원했다. scalar object에서 `inputSchema`/`responseSchema` macro와 `addTypedDocumentedRoute`로 `FieldSpec`를 생성하고 registry 기반 nested DTO OpenAPI `$ref`/cycle schema, router 기반 idempotent `collectRoutes`, metadata 기반 `addModelDocumentedRoute`를 추가했으며 type-erased generic handler closure의 무리한 자동 body 추론은 지원하지 않는다.
- [x] 기존 FieldSpec 검증을 재사용하는 HTML form binding/render context와 escaping/CSRF hidden input을 제공하고, request-scoped token을 middleware·form renderer 사이에 연결한다.
- [-] 독립 template engine의 auto-escaping, inheritance/block, include, filter registry, nested `if/else/endif` block과 `registerTag` custom helper registry, 명시적 `TemplateRenderContext` collection loop를 제공하고 locale catalog 기반 `registerTranslation`/`translate`, JSON `loadTranslationFile` 및 deterministic `loadTranslationDirectory`를 추가했다. `Request.locale`/`Request.timezoneOffsetMinutes`와 `localeMiddleware`의 Accept-Language 협상, 명시적 timezone offset 및 `timezones` 기반 IANA/DST 날짜·시간과 locale 숫자 formatter도 연결했으며 고급 AST tag/helper와 동적 nested collection projection은 후속 범위다.
- [x] metadata 기반 CRUD resource contract, in-memory reference store와 collection/detail route convention을 제공한다.
- [x] metadata-driven SQLite/PostgreSQL repository CRUD와 `ResourceStore` route adapter, secure admin registry 기초를 추가했다. 일반 CRUD와 admin list에 공통 query 실행, `AuthorizationPolicy` guard와 append-only audit event store 계약을 연결하고 admin별 query pagination/cursor 정책, read-only field enforcement, custom list column projection, bulk delete action, 명시적 inline PATCH route와 안전한 form layout renderer hook을 지원하며 SQLite repository store 통합 회귀를 검증했다.
- [x] embedding/standalone CLI의 `openapi [PATH]`가 등록 router를 수집해 OpenAPI 3.1 문서를 stdout 또는 파일로 생성하고, 출력 경로·인자 오류와 route `operationId` 보존을 회귀 테스트로 검증한다.
- [x] Application 소유 `AdminUserCreator`와 account store/password hasher adapter를 연결하고, 비밀번호를 `MAHANAIM_ADMIN_PASSWORD`에서만 읽는 `admin create-user <identifier> [subject]` CLI 및 중복 생성 회귀 테스트를 추가한다.
- [x] `static collect <source...> --output <path>`가 정적 파일을 deterministic manifest 순서로 복사하고, 중복 경로·기존 파일·source 내부 output·symbolic link를 전용 오류로 거부하도록 구현한다.
- [x] backend-neutral `ObjectStorage`/`CacheStore` 계약과 bounded in-memory adapter를 추가하고, key traversal·TTL·oldest eviction을 검증한다. S3-compatible transport bridge는 signing/retry를 application-owned transport로 분리한다.
- [x] Redis/Valkey cache wire adapter를 추가한다. 공통 RESP command encoder와 bounded frame reader를 재사용하고 `GET`·`SETEX`·`SET`·`DEL` 응답 계약을 검증한다. 실제 Redis 연결은 기존 loopback RESP 테스트, cache 의미는 fake transport 테스트로 검증한다.

## P2 — 운영·확장성

- [x] request ID, 구조화 request event sink, 기본 request/error/in-flight metrics, health/readiness endpoint를 제공한다.
- [x] structured request logging sink과 W3C trace/span propagation 기반을 제공한다.
- [x] 구현된 rate limit/timeout/retry/backpressure/graceful shutdown의 실패·복구 운영 정책을 문서화한다.
- [-] distributed rate-limit clock/TTL/eviction, durable queue와 외부 DB drain 운영을 완성한다. SQLite durable queue의 named handler 실행·복구 CLI와 애플리케이션 shutdown close 경계, in-memory rate-limit의 monotonic TTL·bounded oldest eviction은 구현했으며, Redis/Valkey 분산 eviction과 외부 queue·DB drain은 운영 환경 검증이 남아 있다.
- [x] versioned plugin manifest와 명시적 registration phase를 기존 Plugin API와 호환되게 제공한다.
- [x] application/request/task scope를 구분하는 최소 DI provider와 dependency resolution을 제공한다.
- [x] command/admin extension point와 dependency graph resolution을 제공한다.
- [x] executor 기반 background job abstraction과 bounded asynchronous retry 정책을 제공한다.
- [-] background job에 `IdempotencyStore`/in-memory·append-only file·SQLite claim-release adapter와 `enqueueIdempotent`, SQLite durable job payload의 claim/complete/release/recoverProcessing state machine, named-kind handler registry와 bounded executor runner, application-owned `jobs run [max]|recover` bounded drain CLI를 추가했다. 외부 queue callback bridge도 제공하며, 실제 provider protocol·visibility timeout·ack 정책은 application-owned 범위다.
- [-] backend-neutral database test fixture와 SQLite transaction rollback isolation을 제공하고, 환경 기반 PostgreSQL fixture factory 및 `newPostgresTestFixtureFromEnv` convenience API를 추가했다. PostgreSQL live fixture에 isolation·repository route·DDL rollback contract를 연결했지만 credential 부재로 local live 실행은 건너뛰며, live-server fixture와 WebSocket/SSE test client 계약도 추가했다.

## P3 — 선택 확장

- [ ] 추가 HTTP backend와 deployment adapter를 제공한다.
- [ ] 고급 template engine, OpenAPI UI, WebSocket/SSE 고급 기능을 확장한다.
- [-] migration command parser/runner의 `status/up/rollback` 계약과 SQLite 실행, 명시적 migration provider registry, atomic `db seed`와 Application-aware `db status|up|rollback` CLI, metadata migration 생성과 schema diff/check을 추가했다. 환경 기반 PostgreSQL fixture, 명시적 read-only `AdminRegistry` CLI inspector, application-owned durable `jobs run [max]|recover` command도 추가했으며 live fixture 증거는 남아 있다.

## 탄탄한 기반을 위한 설계 규칙

1. **도메인 계약 우선**: Prologue는 transport adapter로 격리하고 core 타입이 Prologue 타입을 노출하지 않게 한다.
2. **단일 책임**: request 변환, route matching, middleware, security, response rendering, lifecycle을 별도 모듈로 유지한다.
3. **명시적 실행 경계**: sync/blocking 작업은 executor를 통해서만 실행하고 cancellation·timeout 계약을 함께 둔다.
4. **실패를 타입화**: 검증·라우팅·설정·보안 오류를 상태 코드와 구조화된 envelope로 일관되게 반환한다.
5. **보안 기본값**: secure cookie/header, body limit, host/CORS 정책을 opt-out이 아닌 안전한 기본값으로 둔다.
6. **테스트 피라미드**: 순수 core unit test → adapter contract test → 실제 loopback/live-server smoke test 순서로 검증한다.
7. **문서와 코드를 함께 변경**: 기능을 완료할 때 구현 체크, 테스트 체크, 문서 체크, CI 검증을 같은 커밋 단위로 남긴다.
8. **확장점은 늦게 공개**: 내부 구현을 먼저 안정화하고 plugin/DI/backend API는 최소 계약으로 공개한다.

## 완료 판정

- [ ] P0의 미완료 항목이 없고, 전체 테스트·verify·check가 통과한다.
- [ ] P1에서 SQLite/PostgreSQL CRUD와 migration 회귀 테스트가 통과한다.
- [x] 구현된 운영 기능은 [운영 정책 문서](docs/operations-guide.md)에 실패 시나리오와 복구 절차를 기록한다.
- [-] 지원 Nim/OS, 의존성 lock, 보안 기본값, 외부 live gate와 변경 로그 규칙을 [`docs/support-policy.md`](docs/support-policy.md)와 `CHANGELOG.md`에 고정했다. 실제 릴리스별 gate 증거와 변경 항목 누적은 진행 중이다.
- [x] 관계 로딩: 기존 JOIN 기반 `listRelation` 계약은 유지하고, `listRelationWithRelated`로 one-to-many 배열과 many-to-one 중첩 객체를 eager loading한다. one-to-many와 through metadata 기반 many-to-many 모두 parent page 기준 batched query를 지원한다.

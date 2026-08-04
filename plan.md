# Mahanaim 구현 계획

> 체크박스 규칙: `[x]`는 구현·테스트·문서화까지 완료한 항목이고, `[ ]`는 미완료 또는 진행 중인 항목이다. 부분 완료 항목은 본문에 남은 범위를 기록한다.

### Custom model field foundation

- [x] `newModelCustomField(name, wireType)`로 임의 Nim custom type을 명시적 JSON/wire metadata 경계에 연결한다.
- [x] custom field 선언의 중복·미존재 필드를 model macro 단계에서 거부한다.
- [x] PostgreSQL live 환경에서 custom field codec과 typed result mapping을 검증한다. PostgreSQL 16 컨테이너에서 JSONB OID 3802 metadata와 `money` wire codec을 실제 query 결과에 적용했다.

### Template collection rendering

- [x] `TemplateRenderContext`와 명시적 collection 등록 API를 추가하고 `{% for item in collection %}` loop의 중첩·조건문·자동 escaping을 회귀 테스트한다.
- [x] 동적 nested collection projection과 AST-aware `TemplateHelperArgument`/`registerHelper`를 추가하고, `TemplateNode` 구조형 AST parser/render 경계로 if/for/include/block/helper/tag/variable의 중첩·quoted literal·named argument를 검증했다.

## 2026-08-04 transaction contract

- [x] DatabaseAdapter transaction guard가 성공 시 commit, 예외 시 rollback을 보장한다.
- [x] backend가 지원하지 않는 savepoint 연산은 명시적으로 실패하도록 계약화했다.
- [x] fake adapter 회귀 테스트와 `nimble test`를 통과했다.
- [x] SQLite driver의 transaction/savepoint/migration up·down history와 PostgreSQL libpq adapter, backend capability/isolation contract를 추가했다. 환경 기반 `postgres_testing` rollback fixture factory, compile gate와 선택적 `postgresLive` contract task를 추가했고 PostgreSQL 16 live task에 shared migration command의 status/up/idempotency/schema-history/rollback, repository CRUD route·serializable isolation·DDL rollback, real pool/session commit·rollback·isolation·close, HTTP/SSE/WebSocket live-server request/response 검증을 연결했다.

## 2026-08-04 executor lifecycle 안정화

- [x] taskpool job registry에서 GC 관리 `Table/seq`를 shared memory에 저장하지 않도록 raw slot registry로 분리한다.
- [x] job closure의 GC root 해제를 event-loop의 Flowvar 완료 이후로 제한한다.
- [x] executor backend를 실제 sync 작업 시점에 lazy 초기화하고 반복 application lifecycle 회귀 테스트를 추가한다.

## 2026-08-04 P0 분산 rate-limit store

- [x] 원자적 remote counter 결과를 표현하는 `RateLimitCounterClient` 계약과 `RedisValkeyRateLimitStore` adapter를 제공한다.
- [x] bounded immediate retry와 backend 오류 fail-closed 503 경로를 회귀 테스트한다.
- [x] Redis/Valkey RESP client, server-side TTL 응답과 loopback live socket fixture를 추가하고 bounded retry·fail-closed 및 장애 후 재연결 회귀 경로를 검증했다. TCP coalescing frame buffer, `INFO server`, `CONFIG GET`, `COMMAND INFO` 기반의 Redis/Valkey version·필수 RESP command·maxmemory·eviction compatibility probe, 환경 기반 `redisLive` contract와 requests/success/failure/connection/reconnect snapshot metrics를 제공한다. Linux Nim 2.2.4 matrix에서 Redis 7.2.15와 Valkey 8.1.9의 실제 PING·command·bounded eviction·server-side TTL 검증을 완료했다.

상태: 진행 중  
작성일: 2026-08-04  
상세 요구사항: [docs/nim-fullstack-framework-requirements.md](docs/nim-fullstack-framework-requirements.md)  
상세 실행 기록: [docs/nim-fullstack-framework-implementation-plan.md](docs/nim-fullstack-framework-implementation-plan.md)

이 문서는 요구사항을 구현 가능한 단위로 추적하기 위한 상위 체크리스트다. 각 항목은 코드, 테스트, 문서가 함께 완료될 때 `[x]`로 변경한다.

## 현재 실행 큐

아래 큐는 우선순위와 의존성을 반영한 다음 작업 순서다. 한 항목은 구현, 회귀 테스트, 관련 문서, 검증 게이트를 모두 통과한 뒤에만 `[x]`로 표시한다. 외부 서비스나 staging 자격 증명이 필요한 항목은 로컬 코드 완료와 live 증거 수집을 분리한다.

### P0 — 안전한 기본 경계와 외부 검증

- [x] **P0-01 PostgreSQL live typed contract** — PostgreSQL 16 컨테이너에서 custom field codec, JSONB OID typed result, serializable transaction, repository CRUD/aggregate/relation, migration up/idempotency/rollback을 실행했다. `tests/test_postgres_live.nim`과 운영 문서에 실행 조건·결과를 기록했다.
- [-] **P0-02 HTTPS deployment boundary** — `Request`의 adapter scheme/peer와 명시적 `trustedProxies`를 통해 forwarded scheme/host를 제한하고, `requireHttps`·secure cookie/header·allowed host 계약과 회귀 테스트·운영 문서를 연결했다. `checkApplication`은 HTTPS 강제 정책에서 공개 `allowedHosts`가 비어 있으면 warning을 출력하고, Linux CI는 `httpsLiveCheck` compile gate와 URL 미설정 명시적 skip을 실행한다. 재현 가능한 Docker nginx TLS 1.2/1.3 → Nim 2.2.4 upstream wire fixture와 `httpsLive` staging client를 추가하고 cold cache readiness window를 보완해 HTTP→HTTPS redirect, handshake·proxy hop·cookie를 통과시켰으며, 운영 staging endpoint의 trusted certificate/renewal 증거는 남아 있다.
- [x] **P0-03 첫 수직 슬라이스 통합 계약** — SQLite metadata migration이 타입과 자동 증가 PK를 보존하도록 고정하고, `mahanaim new` 생성 앱과 하나의 Application lifecycle에서 JSON/admin CRUD, validation·CSRF·session·admin 권한, OpenAPI route collection, test client, health·request ID·startup/shutdown을 검증했다. `tests/test_core.nim`의 통합 fixture, 생성 프로젝트 fixture와 상세 실행 계획·변경 로그를 함께 갱신했다.

### P1 — 핵심 제품 기능의 남은 범위

- [x] **P1-01 구조형 template AST** — `TemplateNode` 구조형 AST parser/render를 추가하고 block/include/helper 인자를 typed node로 검증했다. nested collection projection, quoted literal, named argument, 교차 종료 태그의 parser/render regression test와 사용자 문서를 함께 반영했다.
- [x] **P1-02 PostgreSQL migration evidence** — PostgreSQL adapter의 migration history table, transactional up/down, idempotent migrate, status/latest rollback 및 shared command overload를 compile/live contract에 연결했다. PostgreSQL 16 컨테이너에서 shared command status/up/migrate/status/history/rollback/status를 통과했고 SQLite/PostgreSQL capability·isolation 차이를 운영 contract report로 기록했다.
- [x] **P1-03 DB pool/live HTTP contract** — 실제 TCP 요청이 `Application.dispatch`의 request-scoped database pool borrow/release를 통과하고, 응답 후 idle 반환·shutdown 후 pool close를 보장하는 SQLite fixture를 추가했다. PostgreSQL 16 컨테이너의 `postgresLive`에서도 pool/session commit·rollback·isolation·close와 PostgreSQL-backed HTTP/SSE/WebSocket wire 경로를 실제로 통과시켰다.
- [x] **P1-04 공통 DML 결과 계약** — `DatabaseResult.affectedRows`와 `statementKeyword`/`statementMutatesRows` 공통 판별 계약을 추가하고, SQLite는 connection-local `changes()`, PostgreSQL은 command tag 또는 `RETURNING` row 수를 backend-neutral 결과로 반환한다. SQLite 회귀 테스트와 PostgreSQL 16 live insert contract를 통과시켰다.

### P2/P3 — 운영 호환성과 선택적 확장

- [x] **P2-01 Redis/Valkey compatibility** — TCP coalescing frame buffer와 환경 기반 `redisLive` contract를 추가하고, `INFO server`, `CONFIG GET maxmemory-policy/maxmemory`, `COMMAND INFO`로 Redis/Valkey flavor·version·필수 RESP command·bounded eviction 상태를 진단하는 probe와 회귀 테스트·운영 문서를 추가했다. Linux Nim 2.2.4 matrix에서 Redis 7.2.15와 Valkey 8.1.9의 server-side TTL·command·bounded eviction을 실제 socket으로 확인했고 reconnect/fail-closed는 loopback contract로 검증했다.
- [x] **P3-01 Beast/httpx live adapter** — Linux runner용 실제 TCP/WebSocket fixture와 `beastLiveCheck`/`beastLive` gate를 추가하고 `forget()` 후 async selector 등록·`AsyncSocket` lifetime을 명시했다. unbuffered client wire test에서 handshake, masked text echo, close frame, handler finalization을 통과시켰다.

### 완료 판정

- [ ] 항목별 구현·단위/계약 테스트·문서가 같은 변경에 포함되어 있다.
- [x] 로컬 공통 게이트 `nimble test`, `nimble verify`, `nimble check`, `git diff --check`가 통과한다.
- [ ] 외부 환경 항목은 성공 로그 또는 자격 증명 부재에 대한 명시적 skip 증거가 있다.
- [x] 변경 로그와 상세 실행 계획이 `plan.md`의 상태와 일치한다.

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
- [x] Beast/httpx adapter overload의 Linux compile contract와 stdlib/Beast 공통 WebSocket representation boundary를 추가했다. 실제 Beast live fixture에서 socket ownership handoff, handshake, masked text echo, server close frame, handler finalization을 `beastLive` gate로 검증했다.
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
- [x] signed session cookie와 교체 가능한 `AuthBackend`, HMAC bearer token adapter를 `AuthContext` 및 required authentication route의 401 정책에 연결하고, `authBackends` provider 목록으로 session과 bearer를 한 route에서 조합하며 SessionPolicy primary/legacy secret rotation을 제공한다. JWT·external introspection adapter는 후속 범위다.
- [x] role/group permission, object-level policy와 route guard를 독립 `AuthorizationPolicy` 모듈로 제공한다.
- [-] algorithm-neutral `PasswordHasher` 계약과 `nimcrypto` PBKDF2-HMAC-SHA256 reference adapter, `argon2` C-backed Argon2id adapter, Nim maintained pure bcrypt adapter, per-password salt/parameter encoding, work-factor 판단·`verifyAndRehash` rotation, current-password 검증 기반 `changePassword`, stateless signed reset token/expiry 검증, atomic one-time reset token store, 교체 가능한 login throttling hook과 in-memory·distributed counter adapter를 제공한다. adapter-neutral account store와 login/logout/password-change/password-reset request·confirm route flow, Argon2/bcrypt hash·verify benchmark harness와 Windows/Linux CI contract도 추가했으며 실제 production benchmark 결과 확정은 후속 범위다.
- [-] 기본 `defaultConfig`의 30초 request timeout과 `defaultSecurityPolicy`의 60초당 1000건 bounded rate limit, request size·secure cookie 정책과 HTTPS reverse-proxy 배포 점검표를 `docs/operations-guide.md`에 문서화하고 contract test 범위를 명시했다. `check`의 공개 host 고정 warning까지 연동했으며, 실제 인증서·proxy hop·TLS wire와 운영 staging 검증은 후속 범위다.
- [x] 공유 가능한 backend-neutral rate limit store 계약과 메모리 구현을 연결한다.
- [x] Redis/Valkey RESP adapter와 bounded retry, socket timeout, 실패 시 연결 폐기 및 재연결 회귀 검증, TCP coalescing frame buffer, 운영용 snapshot metrics, version·필수 command·maxmemory·eviction compatibility probe와 환경 기반 live contract를 구현했다. Linux Nim 2.2.4 matrix에서 Redis 7.2.15와 Valkey 8.1.9를 검증했다.
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
- [x] Beast/httpx ownership overload를 `beastCheck`/`beastLiveCheck` compile gate와 Linux TCP/WebSocket `beastLive` fixture로 검증했다. httpx callback handoff 후 async selector pump, handshake, frame, graceful close를 실제 wire에서 통과시켰다.

### 개발 품질

- [x] `nimble test`, `nimble verify`, `nimble check`를 CI와 동일하게 실행한다.
- [x] lockfile 기반 dependency 설치와 기본 CI를 구성한다.
- [x] `new` 프로젝트 생성기가 환경 변수 예제·안전한 `.gitignore`와 함께 SQLite metadata migration, JSON/admin CRUD, session·CSRF 인증, OpenAPI route collection, health/request ID/lifecycle을 검증하는 앱 모듈·실제 dispatch 테스트를 생성하도록 확장한다.
- [-] 지원 OS/Nim 2.2.4 matrix에서 test·verify·check·build를 실행하고 OS별 release candidate와 SHA-256 checksum artifact를 생성하도록 CI를 확장했다. Windows runner에는 PostgreSQL client runtime(`libpq.dll`) 설치 경계를 추가했으며, 실제 GitHub runner 실행 결과와 추가 지원 버전 확대는 후속 검증 범위다.
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
- [x] SQLite/PostgreSQL query·transaction adapter, 공통 `DatabaseResult`/column metadata contract, SQLite 선언 타입·runtime storage class 및 PostgreSQL type OID 기반 typed scalar result mapping, QuerySet/aggregate compiler와 repository aggregate result mapping, aggregate route adapter, migration history/JOIN compiler, typed row-lock mode, bounded pool, request session의 active isolation 설정, capability matrix와 metadata repository relation execution을 제공했다. PostgreSQL live task에 serializable isolation, repository CRUD route, typed metadata, custom JSONB wire codec, filtering, grouped aggregate, one-to-many relation, DDL rollback, pool/session commit·rollback·close, HTTP/SSE/WebSocket live-server request 검증을 연결했고 source compile gate도 추가했다. PostgreSQL 16 컨테이너에서 live contract를 통과했다.

### API와 서버 렌더링

- [x] named field extraction, scalar coercion, validation error aggregation을 제공한다.
- [x] 명시적 input schema에서 OpenAPI 3.1 문서와 제약조건을 생성한다.
- [x] parameterized query contract에 bounded pagination page/size/offset 정책을 연결한다.
- [x] 공통 query component로 pagination/filter/sort/field-selection과 typed cursor filter/token 변환, signed/expiring next cursor metadata, opt-in total metadata, metadata-driven aggregate expression parser, query validation 오류 형식을 제공하고 QuerySet aggregate SQL compiler/repository mapping/route, typed arithmetic annotate projection, eager one-hop/many-to-many through loading과 명시적 lazy relation loader를 추가했다. one-to-many와 many-to-many 모두 parent page 기준 bound `IN` batching을 적용했다.
- [x] Accept quality(`q`) 우선순위와 `q=0` 거부를 포함한 content negotiation을 제공한다.
- [-] explicit typed response schema와 HTML/text/JSON/file/redirect/stream/SSE/WebSocket response helper, HTML·HTMX partial·JSON 선택 helper, 다중 route OpenAPI registry와 operation별 다중 content type, Swagger/ReDoc UI route를 추가하고 `addDocumentedRoute`로 route/schema 동시 등록을 지원했다. scalar object에서 `inputSchema`/`responseSchema` macro와 `addTypedDocumentedRoute`로 `FieldSpec`를 생성하고 registry 기반 nested DTO OpenAPI `$ref`/cycle schema, router 기반 idempotent `collectRoutes`, metadata 기반 `addModelDocumentedRoute`를 추가했으며 type-erased generic handler closure의 무리한 자동 body 추론은 지원하지 않는다.
- [x] 기존 FieldSpec 검증을 재사용하는 HTML form binding/render context와 escaping/CSRF hidden input을 제공하고, request-scoped token을 middleware·form renderer 사이에 연결한다.
- [x] 독립 template engine의 auto-escaping, `TemplateNode` 구조형 AST 기반 inheritance/block, include, filter registry, nested `if/else/endif`, `for` collection loop와 `registerTag`/`registerHelper` registry를 제공하고 locale catalog 기반 `registerTranslation`/`translate`, JSON `loadTranslationFile` 및 deterministic `loadTranslationDirectory`를 추가했다. `Request.locale`/`Request.timezoneOffsetMinutes`와 `localeMiddleware`의 Accept-Language 협상, 명시적 timezone offset 및 `timezones` 기반 IANA/DST 날짜·시간과 locale 숫자 formatter도 연결했다.
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
- [x] backend-neutral database test fixture와 SQLite transaction rollback isolation을 제공하고, 환경 기반 PostgreSQL fixture factory 및 `newPostgresTestFixtureFromEnv` convenience API를 추가했다. PostgreSQL live fixture에 isolation·repository route·custom codec·DDL rollback·pool/session·HTTP/SSE/WebSocket live-server contract를 연결했고 PostgreSQL 16 컨테이너에서 통과했다.

## P3 — 선택 확장

- [ ] 추가 HTTP backend와 deployment adapter를 제공한다.
- [ ] 고급 template engine, OpenAPI UI, WebSocket/SSE 고급 기능을 확장한다.
- [x] migration command parser/runner의 `status/migrate/up/rollback` 계약과 SQLite 실행, PostgreSQL migration history runner, 명시적 migration provider registry, atomic `db seed`와 Application-aware `db status|migrate|up|rollback` CLI, standalone `admin`/`jobs` 진입점, metadata migration 생성과 schema diff/check을 추가했다. 환경 기반 PostgreSQL fixture에서 shared migration command와 schema history live evidence를 통과했고, 명시적 read-only `AdminRegistry` CLI inspector, application-owned durable `jobs run [max]|recover` command도 연결했다.

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

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
- [-] **P0-02 HTTPS deployment boundary** — `Request`의 adapter scheme/peer와 명시적 `trustedProxies`를 통해 forwarded scheme/host를 제한하고, `requireHttps`·secure cookie/header·allowed host 계약과 회귀 테스트·운영 문서를 연결했다. `checkApplication`은 HTTPS 강제 정책에서 공개 `allowedHosts`가 비어 있으면 warning을 출력하고, Linux CI는 `httpsLiveCheck` compile gate와 URL 미설정 명시적 skip을 실행한다. 2026-08-05 로컬에서 Docker nginx 1.27.5 TLS reverse proxy와 Nim/Linux 2.2.4 upstream wire fixture를 재실행해 HTTP→HTTPS redirect와 HTTPS reverse-proxy live contract를 통과시켰다. 운영 staging endpoint의 trusted certificate/renewal 증거는 남아 있다.
- [x] **P0-03 첫 수직 슬라이스 통합 계약** — SQLite metadata migration이 타입과 자동 증가 PK를 보존하도록 고정하고, `mahanaim new` 생성 앱과 하나의 Application lifecycle에서 JSON/admin CRUD, validation·CSRF·session·admin 권한, OpenAPI route collection, test client, health·request ID·startup/shutdown을 검증했다. `tests/test_core.nim`의 통합 fixture, 생성 프로젝트 fixture와 상세 실행 계획·변경 로그를 함께 갱신했다.
- [x] **P0-05 live-server smoke fixture** — 실제 loopback NetworkServer를 ephemeral port로 시작·readiness polling하고, `NetworkTestClient`가 wire HTTP 응답을 core `Response`로 정규화하도록 추가했다. fixture의 idempotent shutdown과 실제 TCP status·header·body를 contract test로 검증했으며, backend별 고급 live fixture는 별도 gate로 유지한다.

- [x] **P0-06 dependency lock integrity** — `nimble.lock`의 JSON version, package metadata, required direct dependency, SHA-1 checksum shape를 재사용 가능한 `validateDependencyLock` contract로 검증하고 `nimble lockCheck`를 `verify` gate에 연결했다. 실제 clean OS runner dependency 설치 결과는 matrix gate에서 별도로 축적한다.
- [x] **P0-07 CI live fixture wiring** — PostgreSQL 16 service에 이어 verify job에 Redis 7.2 service와 health check, `MAHANAIM_REDIS_*` 설정, `redisLiveCheck`/`redisLive` 실행을 연결했다. bounded eviction 설정은 disposable CI container에서만 `MAHANAIM_REDIS_CONFIGURE=true`로 허용하고 ambient/external Redis는 변경하지 않는다.

### P1 — 핵심 제품 기능의 남은 범위

- [x] **P1-01 구조형 template AST** — `TemplateNode` 구조형 AST parser/render를 추가하고 block/include/helper 인자를 typed node로 검증했다. nested collection projection, quoted literal, named argument, 교차 종료 태그의 parser/render regression test와 사용자 문서를 함께 반영했다.
- [x] **P1-02 PostgreSQL migration evidence** — PostgreSQL adapter의 migration history table, transactional up/down, idempotent migrate, status/latest rollback 및 shared command overload를 compile/live contract에 연결했다. PostgreSQL 16 컨테이너에서 shared command status/up/migrate/status/history/rollback/status와 transaction-scoped advisory-lock concurrent migration convergence를 통과했고 SQLite/PostgreSQL capability·isolation 차이를 운영 contract report로 기록했다.
- [x] **P1-03 DB pool/live HTTP contract** — 실제 TCP 요청이 `Application.dispatch`의 request-scoped database pool borrow/release를 통과하고, 응답 후 idle 반환·shutdown 후 pool close를 보장하는 SQLite fixture를 추가했다. PostgreSQL 16 컨테이너의 `postgresLive`에서도 pool/session commit·rollback·isolation·close와 PostgreSQL-backed HTTP/SSE/WebSocket wire 경로를 실제로 통과시켰다.
- [x] **P1-04 공통 DML 결과 계약** — `DatabaseResult.affectedRows`와 `statementKeyword`/`statementMutatesRows` 공통 판별 계약을 추가하고, SQLite는 connection-local `changes()`, PostgreSQL은 command tag 또는 `RETURNING` row 수를 backend-neutral 결과로 반환한다. SQLite 회귀 테스트와 PostgreSQL 16 live insert contract를 통과시켰다.
- [x] **P1-05 request/response DTO 경계** — typed documented route가 request DTO와 response DTO를 독립적으로 schema화해 입력 전용 `age`가 응답에 노출되지 않고 응답 전용 `id`가 입력에 요구되지 않도록 회귀 테스트로 고정했다. rename·partial update·nested·sensitive exclusion은 기존 metadata serializer contract에서 함께 검증한다.
- [x] **P1-06 공통 runtime content negotiation** — `Application.dispatch`가 in-process client와 모든 transport adapter의 response variant를 같은 `Accept` 정책으로 선택하고, 406·`Vary: Accept`·stream/SSE/WebSocket 표현 경계를 공통 계약으로 보장한다. adapter별 중복 negotiation은 제거했다.
- [x] **P1-09 PostgreSQL typed row-lock live contract** — `QueryLockMode`의 `FOR UPDATE`·`FOR SHARE`를 PostgreSQL serializable `DatabaseSession`에서 실제 실행하고 결과·commit lifecycle과 두 session 간 bounded `lock_timeout` contention을 검증했다. SQLite는 unsupported capability를 계속 fail fast하며, aggregate lock도 명시적으로 거부한다.

### P2/P3 — 운영 호환성과 선택적 확장

- [x] **P2-01 Redis/Valkey compatibility** — TCP coalescing frame buffer와 환경 기반 `redisLive` contract를 추가하고, `INFO server`, `CONFIG GET maxmemory-policy/maxmemory`, `COMMAND INFO`로 Redis/Valkey flavor·version·필수 RESP command·bounded eviction 상태를 진단하는 probe와 회귀 테스트·운영 문서를 추가했다. Linux Nim 2.2.4 matrix에서 Redis 7.2.15와 Valkey 8.1.9의 server-side TTL·command·bounded eviction을 실제 socket으로 확인했고 reconnect/fail-closed는 loopback contract로 검증했다.
- [x] **P2-02 plugin 확장 경계** — Application 소유 serialization codec registry, named object storage registry, ordered auth backend 등록 API를 추가해 plugin이 route·DI·middleware·command·metadata·admin과 같은 명시적 경계로 serializer·storage·auth를 확장하도록 했다. 중복 등록과 실제 codec/storage/auth 연결을 plugin contract test로 검증했다.
- [x] **P2-05 DI scope·graph·disposal** — application scope singleton과 명시적 child scope의 request/task ownership, dependency factory의 graph resolution·cycle rejection, request dispatch 자동 scope 생성·정리, reverse-order disposer와 Application shutdown disposal을 추가하고 contract test로 검증했다.
- [x] **P2-06 class-based controller boundary** — framework-neutral `Controller.handle(action, request)` virtual contract와 `addControllerRoute` bridge를 추가해 route/middleware/DI/error lifecycle은 Application이 소유하고 action dispatch만 controller가 소유하도록 분리했다. concrete controller route dispatch와 빈 action validation을 회귀 테스트했다.
- [x] **P2-07 구현계획 증거 정합화** — backend-neutral object storage, WebSocket adapter, OpenAPI UI와 HTML·JSON·upload·WebSocket 수직 경로의 기존 구현·계약 테스트를 구현계획에 반영하고, S3 signing/retry·compression·rolling deployment 같은 외부/후속 범위는 부분 완료 상태로 명시했다. 문서 계약 테스트로 완료 baseline과 남은 운영 증거가 함께 유지되는지 검증했다.
- [x] **P2-03 서버 렌더링 flash message contract** — session key별 bounded FIFO `FlashStore`와 기본 in-memory adapter를 추가하고, consume-once·session isolation·capacity eviction을 `Application.flashStore`에서 제공한다. durable/distributed adapter는 동일 contract를 구현할 수 있는 확장 경계로 남긴다.
- [x] **P2-04 syndication/email contract** — framework-neutral XML renderer로 absolute HTTP URL을 검증하고 XML escaping, deterministic caller order, sitemap metadata, RSS 2.0 channel/item, Atom 1.0 feed/entry를 제공한다. `EmailMessage` RFC 5322 simple-part serializer와 `EmailTransport`/in-memory·wire callback adapter도 추가해 mailbox·header injection·recipient·content-type 경계를 검증한다. 외부 SMTP socket·credential·retry provider 정책은 callback을 소비하는 application-owned adapter 범위로 남긴다.
- [x] **REQ-OPS-005 template formatter 주입** — `TemplateRenderContext`에 request-owned `LocaleFormatPolicy` snapshot을 명시적으로 연결하고 `format_decimal`·`format_datetime` built-in helper를 자동 제공한다. formatter 미설정·잘못된 값·reserved helper 재등록을 fail fast하며 form/API 자동 주입과 고급 formatting은 별도 범위로 남긴다.
- [x] **REQ-OPS-006 조건부 응답** — buffered response에 deterministic strong `ETag`를 부여하고 `If-None-Match`의 weak comparison을 공통 dispatch 경계에서 처리해 `GET`/`HEAD` 일치 요청을 304로 반환한다. stream/SSE/WebSocket 표현은 cache validator 대상에서 제외한다.
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
- [x] algorithm-neutral `PasswordHasher` 계약과 `nimcrypto` PBKDF2-HMAC-SHA256 reference adapter, `argon2` C-backed Argon2id adapter, Nim maintained pure bcrypt adapter, per-password salt/parameter encoding, work-factor 판단·`verifyAndRehash` rotation, current-password 검증 기반 `changePassword`, stateless signed reset token/expiry 검증, atomic one-time reset token store, 교체 가능한 login throttling hook과 in-memory·distributed counter adapter를 제공한다. adapter-neutral account store와 login/logout/password-change/password-reset request·confirm route flow, Argon2/bcrypt hash·verify benchmark harness와 Windows/Linux CI contract도 추가했다.
- [x] 2026-08-05 개발 호스트 release-like baseline을 `docs/operations-guide.md`에 기록했다(Argon2id hash/verify 117/119 ms, bcrypt work factor 12 hash/verify 249/250 ms, samples=5).
- [-] 실제 production benchmark 결과와 concurrent memory/login load에 따른 cost 확정은 배포 환경에서 후속 검증한다.
- [x] 기본 `defaultConfig`의 30초 request timeout과 `defaultSecurityPolicy`의 60초당 1000건 bounded rate limit, request size·secure cookie 정책과 HTTPS reverse-proxy 배포 점검표를 `docs/operations-guide.md`에 문서화하고 contract test 범위를 명시했다. JSON/TOML provider는 framework-owned scalar의 원본 타입을 schema validation하고 확장 구조는 typed values로 보존하며, `check`의 공개 host 고정 warning까지 연동했다.
- [-] 운영 staging의 실제 인증서·proxy hop·TLS wire 검증은 배포 환경에서 후속 확인한다.
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
- [-] 지원 OS/Nim 2.2.4 matrix에서 Linux·Windows·macOS runner, OS별 PostgreSQL client runtime, release candidate와 SHA-256 checksum artifact 생성을 CI에 연결했다. 실제 GitHub runner 실행 결과와 추가 지원 버전 확대는 후속 검증 범위다.
- [x] Definition of Done 체크리스트를 [`docs/definition-of-done.md`](docs/definition-of-done.md)에 고정하고, 필수 섹션·체크박스 표기·검증 명령을 `validateDefinitionOfDone`/`nimble docsCheck`로 자동 검증하도록 `verify`와 CI에 연결했다.
- [-] 기존 기능에 Definition of Done을 항목별로 적용하고 외부 환경 gate 증거를 누적한다.

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
- [x] SQLite/PostgreSQL query·transaction adapter, 공통 `DatabaseResult`/column metadata contract, SQLite 선언 타입·runtime storage class 및 PostgreSQL type OID 기반 typed scalar result mapping, QuerySet/aggregate compiler와 repository aggregate result mapping, aggregate route adapter, migration history/JOIN compiler, typed row-lock mode, bounded pool, request session의 active isolation 설정, capability matrix와 metadata repository relation execution을 제공했다. PostgreSQL live task에 serializable isolation, `FOR UPDATE`/`FOR SHARE` row-lock execution, repository CRUD route, typed metadata, custom JSONB wire codec, filtering, grouped aggregate, one-to-many relation, DDL rollback, pool/session commit·rollback·close, HTTP/SSE/WebSocket live-server request 검증을 연결했고 source compile gate도 추가했다. PostgreSQL 16 컨테이너에서 live contract를 통과했다.

### API와 서버 렌더링

- [x] named field extraction, scalar coercion, validation error aggregation을 제공한다.
- [x] 명시적 input schema에서 OpenAPI 3.1 문서와 제약조건을 생성한다.
- [x] parameterized query contract에 bounded pagination page/size/offset 정책을 연결한다.
- [x] 공통 query component로 pagination/filter/sort/field-selection과 typed cursor filter/token 변환, signed/expiring next cursor metadata, opt-in total metadata, metadata-driven aggregate expression parser, query validation 오류 형식을 제공하고 QuerySet aggregate SQL compiler/repository mapping/route, typed arithmetic annotate projection, eager one-hop/many-to-many through loading과 명시적 lazy relation loader를 추가했다. one-to-many와 many-to-many 모두 parent page 기준 bound `IN` batching을 적용했다.
- [x] Accept quality(`q`) 우선순위와 `q=0` 거부를 포함한 content negotiation을 제공한다.
- [x] explicit typed response schema와 HTML/text/JSON/file/redirect/stream/SSE/WebSocket response helper, HTML·HTMX partial·JSON 선택 helper, 다중 route OpenAPI registry와 operation별 다중 content type, Swagger/ReDoc UI route를 추가하고 `addDocumentedRoute`로 route/schema 동시 등록을 지원했다. scalar object에서 `inputSchema`/`responseSchema` macro와 `addTypedDocumentedRoute`로 `FieldSpec`를 생성하고 registry 기반 nested DTO OpenAPI `$ref`/cycle schema, router 기반 idempotent `collectRoutes`, metadata 기반 `addModelDocumentedRoute`를 추가했다. runtime content negotiation은 `Application.dispatch` 공통 경계에서 수행한다.
- [-] type-erased generic handler closure에서 DTO body schema를 무리하게 자동 추론하는 기능은 지원하지 않는다. handler와 DTO의 소유권을 명시적으로 유지하는 `addTypedDocumentedRoute` 경계를 사용하며, 자동 추론은 별도 typed handler contract가 정의될 때까지 보류한다.
- [x] 기존 FieldSpec 검증을 재사용하는 HTML form binding/render context와 escaping/CSRF hidden input을 제공하고, request-scoped token을 middleware·form renderer 사이에 연결한다.
- [x] 독립 template engine의 auto-escaping, `TemplateNode` 구조형 AST 기반 inheritance/block, include, filter registry, nested `if/else/endif`, `for` collection loop와 `registerTag`/`registerHelper` registry를 제공하고 locale catalog 기반 `registerTranslation`/`translate`, JSON `loadTranslationFile` 및 deterministic `loadTranslationDirectory`를 추가했다. `Request.locale`/`Request.timezoneOffsetMinutes`와 `localeMiddleware`의 Accept-Language 협상, 명시적 timezone offset 및 `timezones` 기반 IANA/DST 날짜·시간과 locale 숫자 formatter도 연결했다.
- [x] metadata 기반 CRUD resource contract, in-memory reference store와 collection/detail route convention을 제공한다.
- [x] metadata-driven SQLite/PostgreSQL repository CRUD와 `ResourceStore` route adapter, secure admin registry 기초를 추가했다. 일반 CRUD와 admin list에 공통 query 실행, `AuthorizationPolicy` guard와 append-only audit event store 계약을 연결하고 admin별 query pagination/cursor 정책, read-only field enforcement, custom list column projection, bulk delete action, 명시적 inline PATCH route와 안전한 form layout renderer hook을 지원하며 SQLite repository store 통합 회귀를 검증했다.
- [x] **P1-07 서버 렌더링 admin 목록 화면** — 기존 JSON admin list 응답을 유지하면서 `Accept: text/html` 요청에는 공통 query·projection·민감 필드 정책을 재사용한 escaped HTML table과 신규 항목 링크를 제공한다. in-process dispatch에서 JSON/HTML 협상과 기본 목록 회귀를 검증했다.
- [x] **P1-08 서버 렌더링 admin CRUD 화면** — admin detail을 JSON/HTML variant로 제공하고 metadata 기반 edit form, URL-encoded create/update, 명시적 POST delete와 redirect를 추가했다. 기존 authorization·read-only field·audit 경계를 재사용하고 in-process browser-form 회귀를 검증했다.
- [x] embedding/standalone CLI의 `openapi [PATH]`가 등록 router를 수집해 OpenAPI 3.1 문서를 stdout 또는 파일로 생성하고, 출력 경로·인자 오류와 route `operationId` 보존을 회귀 테스트로 검증한다.
- [x] Application 소유 `AdminUserCreator`와 account store/password hasher adapter를 연결하고, 비밀번호를 `MAHANAIM_ADMIN_PASSWORD`에서만 읽는 `admin create-user <identifier> [subject]` CLI 및 중복 생성 회귀 테스트를 추가한다.
- [x] `static collect <source...> --output <path>`가 정적 파일을 deterministic manifest 순서로 복사하고, 중복 경로·기존 파일·source 내부 output·symbolic link를 전용 오류로 거부하도록 구현한다.
- [x] backend-neutral `ObjectStorage`/`CacheStore` 계약과 bounded in-memory adapter를 추가하고, key traversal·TTL·oldest eviction을 검증한다. S3-compatible transport bridge는 signing/retry를 application-owned transport로 분리한다.
- [x] Redis/Valkey cache wire adapter를 추가한다. 공통 RESP command encoder와 bounded frame reader를 재사용하고 `GET`·`SETEX`·`SET`·`DEL` 응답 계약을 검증한다. 실제 Redis 연결은 기존 loopback RESP 테스트, cache 의미는 fake transport 테스트로 검증한다.

## P2 — 운영·확장성

- [x] request ID, 구조화 request event sink, 기본 request/error/in-flight metrics, health/readiness endpoint를 제공한다.
- [x] structured request logging sink과 W3C trace/span propagation 기반을 제공한다.
- [x] 구현된 rate limit/timeout/retry/backpressure/graceful shutdown의 실패·복구 운영 정책을 문서화한다.
- [x] distributed rate-limit의 backend-neutral counter 경계, in-memory monotonic TTL·bounded oldest eviction, Redis/Valkey RESP compatibility probe와 bounded retry/fail-closed 정책을 구현하고 live contract를 연결했다. SQLite durable queue의 named handler 실행·복구 CLI와 애플리케이션 shutdown close 경계도 contract test로 검증했다.
- [-] Redis/Valkey 분산 eviction과 외부 queue·DB drain의 실제 운영 검증은 배포 환경에서 후속 확인한다.
- [x] versioned plugin manifest와 명시적 registration phase를 기존 Plugin API와 호환되게 제공한다.
- [x] application/request/task scope를 구분하는 최소 DI provider와 dependency resolution을 제공한다.
- [x] command/admin extension point와 dependency graph resolution을 제공한다.
- [x] executor 기반 background job abstraction과 bounded asynchronous retry 정책을 제공한다.
- [x] background job에 `IdempotencyStore`/in-memory·append-only file·SQLite claim-release adapter와 `enqueueIdempotent`, SQLite durable job payload의 claim/complete/release/recoverProcessing state machine, named-kind handler registry와 bounded executor runner, application-owned `jobs run [max]|recover` bounded drain CLI를 추가했다. `ExternalDurableJobStore` callback bridge와 shutdown close 경계도 제공한다.
- [x] 닫힌 SQLite durable store의 `complete`·`release`·`recoverProcessing`도 `ValueError`로 명시적 lifecycle 오류를 반환하도록 하고 shutdown race 회귀 테스트를 추가했다.
- [x] `ExternalDurableJobStore`도 close callback을 한 번만 실행하고 shutdown 이후 모든 enqueue/claim/complete/release/recover transition을 명시적 `ValueError`로 거부하도록 보강했다.
- [x] S3-compatible object transport에 application-owned callback을 감싸는 bounded retry decorator를 추가하고, 성공·최종 실패·잘못된 attempt 설정을 contract test로 검증했다. provider-specific signing/backoff와 외부 eviction/queue 운영 검증은 callback·배포 환경 범위로 유지한다.
- [-] 실제 외부 queue provider protocol·visibility timeout·ack 정책의 운영 검증은 application-owned 배포 환경 범위다.
- [x] backend-neutral database test fixture와 SQLite transaction rollback isolation을 제공하고, 환경 기반 PostgreSQL fixture factory 및 `newPostgresTestFixtureFromEnv` convenience API를 추가했다. PostgreSQL live fixture에 isolation·repository route·custom codec·DDL rollback·pool/session·HTTP/SSE/WebSocket live-server contract를 연결했고 PostgreSQL 16 컨테이너에서 통과했다.

## P3 — 선택 확장

- [x] template AST가 `if/elif/else` 조건 분기를 nested `templateIf`로 표현하고 short-circuit 렌더링하도록 확장했으며, true/false branch 회귀 테스트를 추가했다.
- [x] template AST가 빈 collection을 위한 `for/else/endfor` 분기를 지원하고, 항목 존재·부재의 렌더링 회귀 테스트를 추가했다.

- [x] 직접 `httpx` request/response·WebSocket handoff와 application lifecycle을 연결하는 추가 HTTP backend/deployment adapter를 제공하고, Windows 조건부 import·Linux compile contract·설정 validation test 및 `httpxCheck`/`httpxTest` gate를 추가했다.
- [x] OpenAPI registry에서 deterministic TypeScript `fetch` client artifact를 생성하는 `typescriptClient`와 `openapi-ts [PATH]` CLI를 추가하고, typed request/response interface·path/query parameter 변환·CLI 파일 출력을 회귀 테스트했다.
- [-] 고급 template engine, OpenAPI UI, WebSocket/SSE 고급 기능을 확장한다. Loop metadata(`loop.index`, `loop.index0`, `loop.first`, `loop.last`, `loop.length`)는 P3-22에서 완료했고, OpenAPI UI와 WebSocket/SSE 고급 확장은 후속 범위다.
- [x] 표준 WebSocket adapter가 masked fragmented text message를 continuation frame으로 재조립하고, 조립 중 interleaved ping에 pong으로 응답하도록 실제 loopback wire contract를 확장했다.
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

- [x] 2026-08-05 `tests/run_https_wire.ps1`를 실제 실행해 Docker nginx TLS 1.2/1.3 reverse proxy, Nim/Linux upstream, HTTP→HTTPS redirect, trusted forwarded metadata와 secure cookie wire 계약을 통과시켰다. staging 인증서 체인·renewal 증거는 별도 범위다.
- [x] 2026-08-05 disposable Docker PostgreSQL 16과 Redis 7.2.15 service에서 `nimble postgresLive`와 `nimble redisLive`를 실제 실행했다. PostgreSQL advisory-lock concurrent migration, Redis two-process fan-out/reconnect/backpressure/eviction 계약이 통과했으며 GitHub runner와 staging evidence는 별도 범위다.
- [x] 2026-08-05 PostgreSQL live fixture에도 독립 libpq 연결 2개의 concurrent migration 계약을 추가하고 `postgresLiveCheck` compile gate 및 credential 부재 명시적 skip을 검증했다. credential이 제공되는 CI/staging의 실제 실행 로그는 외부 evidence 범위다.
- [x] 2026-08-05 `tests/test_core.nim`에 독립 SQLite 연결 2개가 같은 migration을 동시에 실행하는 계약을 추가해 실패 없이 단일 history row/schema로 수렴하는지 검증했다. PostgreSQL concurrent migration 및 staging 운영 evidence는 별도 범위다.
- [x] 2026-08-05 semantic versioning, 지원 버전/adapter matrix, deprecation migration guide, API maturity label, security release 규칙을 `docs/api-stability-policy.md`와 `docs/support-matrix.md`에 고정하고 문서 계약 테스트로 계획 상태와 정책 artifact의 정합성을 검증했다.
- [x] 2026-08-05 보안 실패·우회 경로를 우선 검증하도록 `tests/test_core.nim`에 untrusted `X-Forwarded-Host`와 missing `Host`의 allowed-host bypass 회귀 테스트를 추가했다. HTTPS/CORS/body-limit/CSRF/session/rate-limit 실패 계약과 함께 로컬 gate에서 검증하고, staging TLS 증거는 별도 범위로 유지한다.
- [x] 2026-08-05 `tests/database_contracts.nim`의 공통 adapter contract를 SQLite unit fixture와 PostgreSQL live fixture에서 재사용해 parameter binding, CRUD 결과와 affectedRows 의미를 같은 코드로 검증했다. backend별 capability와 전체 matrix 증거는 별도 gate 범위다.
- [x] 2026-08-05 `tests/test_public_api_compile.nim`과 `nimble publicApiCheck`를 추가해 public package entry point의 core·route·metadata·serializer·database·storage·template·security·testing 대표 API compile contract를 verify에 연결했다. 전체 exported symbol별 독립 test matrix는 후속 범위다.
- [x] 2026-08-05 `examples/minimal_app.nim`을 추가해 public package import, HTML/JSON route, startup/shutdown과 in-process dispatch를 실행하고 `nimble docsExamples` gate에서 `minimal-app-ok` 및 response invariant를 검증했다.
- [x] 2026-08-05 `docs/api-stability-policy.md`를 추가해 package manifest·lockfile·support matrix와 semantic versioning, `experimental`/`stable`/`deprecated` maturity, migration guide 및 security release 규칙을 연결하고 `docsCheck` 계약 테스트로 drift를 검증했다. clean OS runner와 실제 release artifact 증거는 외부 범위다.
- [x] 2026-08-05 `httpDispatchBenchmark`를 추가해 Application dispatch의 route·security middleware·handler·response 경계를 10,000회 반복하고 HTTP 200/body invariant를 검증했다. socket/production network latency와 버전별 결과 기록은 별도 live/release 범위다.
- [x] 2026-08-05 template AST/render benchmark를 `nimble templateBenchmark` gate로 연결하고 10,000회 workload에서 auto-escaping과 loop metadata output invariant를 검증했다. HTTP benchmark 분리와 버전별 결과 기록은 후속 범위다.
- [x] 2026-08-05 metadata serialization benchmark를 `nimble serializationBenchmark` gate로 연결하고 10,000회 workload에서 JSON name projection과 sensitive-field exclusion invariant를 검증했다. template/HTTP benchmark 분리와 버전별 결과 기록은 후속 범위다.
- [x] 2026-08-05 ORM query compiler benchmark를 `nimble databaseQueryBenchmark` gate로 연결하고 SQLite/PostgreSQL parameter binding과 no-interpolation invariant를 10,000회 workload로 검증했다. serialization/template/HTTP benchmark 분리와 버전별 결과 기록은 후속 범위다.
- [x] 2026-08-05 저장소·ORM 연동 패턴을 framework-neutral 계약, adapter 소유권, 외부 provider/ORM session lifecycle과 공통 contract test matrix로 문서화하고 `docsCheck` 계약 테스트를 추가했다. 실제 provider credential·production 운영 증거는 별도 live 환경 범위로 유지한다.
- [ ] P0의 미완료 항목이 없고, 전체 테스트·verify·check가 통과한다.
- [x] P1에서 SQLite/PostgreSQL CRUD와 migration 회귀 테스트가 통과한다. SQLite core contract와 PostgreSQL 16 live migration/relation evidence를 유지한다.
- [x] 구현된 운영 기능은 [운영 정책 문서](docs/operations-guide.md)에 실패 시나리오와 복구 절차를 기록한다.
- [-] 지원 Nim/OS, 의존성 lock, 보안 기본값, 외부 live gate와 변경 로그 규칙을 [`docs/support-policy.md`](docs/support-policy.md)와 `CHANGELOG.md`에 고정했다. 실제 릴리스별 gate 증거와 변경 항목 누적은 진행 중이다.
- [x] 관계 로딩: 기존 JOIN 기반 `listRelation` 계약은 유지하고, `listRelationWithRelated`로 one-to-many 배열과 many-to-one 중첩 객체를 eager loading한다. one-to-many와 through metadata 기반 many-to-many 모두 parent page 기준 batched query를 지원한다.

### P1-10 migration CLI provider boundary

- [x] Application이 `MigrationDatabaseProvider`를 명시적으로 소유하도록 연결하고, provider가 database location·connection lifecycle·migration command 실행을 책임지게 한다.
- [x] 기본 SQLite CLI 동작은 유지하고, custom provider를 구성한 애플리케이션은 `db status|up|rollback`을 backend-neutral command contract로 실행한다.
- [x] `db seed`는 provider의 open/close lifecycle을 사용하며, CLI가 DSN·credential을 추측하거나 다른 backend로 조용히 fallback하지 않도록 한다.
- [x] provider wiring contract test를 추가하고, standalone 자동 발견은 명시적 application configuration이 필요한 후속 범위로 기록한다.

### P1-11 generated application CLI entrypoint

- [x] `mahanaim new`가 생성하는 애플리케이션 모듈을 실제 실행 진입점으로 사용하도록 연결한다. 생성 모듈의 `when isMainModule`이 `createApp()`과 `commandLineParams()`를 공통 `runCli` 계약에 전달해, standalone 실행이 빈 `newApplication()`을 우회하고 프로젝트 소유 wiring을 사용하게 한다.
- [x] standalone에서 app-owned migration provider와 admin account provisioning callback을 자동 구성한다. 생성 앱은 동일한 migration 정의를 초기 SQLite 준비와 `Application` registry에 공유하고, 인증 account store/hasher 기반 provisioning callback을 명시적으로 등록한다. 저장소/credential 정책은 프로젝트 소유 설정으로 남긴다.

## 2026-08-05 구현 완료 체크

- [x] executor의 active worker capacity와 waiting queue를 분리하고 `maxQueuedJobs` bounded admission 및 `executor_queue_full` 503 contract를 추가했다.
- [x] queue-full 회귀 테스트를 먼저 추가해 named parameter 컴파일 실패를 확인한 뒤 구현하고 `nimble test` green을 확인했다.
- [x] `executorMaxQueuedJobs`를 AppConfig·JSON/TOML·`MAHANAIM_EXECUTOR_MAX_QUEUED_JOBS` provider와 Application executor wiring에 연결하고 음수 설정 pre-flight 회귀 테스트를 추가했다.
- [x] `MAHANAIM_VALUE_<KEY>=<JSON>` 환경변수 structured config 주입과 file provider precedence, malformed JSON 회귀 테스트를 추가했다.

## 2026-08-05 요구사항 감사 완료 체크

- [x] macro schema·response content negotiation, route validation, model metadata, observability, WebSocket/Beast live contract가 현재 구현·테스트·gate에 존재함을 상세 계획에 반영했다.
- [-] 추가 OS runner matrix와 generic handler 자동 DTO 추론은 별도 범위로 명시했다.
- [x] `benchmarks/router_benchmark.nim`을 `nimble routerBenchmark` gate로 연결하고 2,000 route·20,000 iteration workload의 route-hit invariant를 실행했다.
- [x] compressed static radix edge와 first-segment lookup으로 route candidate traversal을 최적화하고 precedence 회귀 테스트를 추가했다.
## 2026-08-05 channel layer foundation

- [x] **P3-02 channel layer foundation** — framework-neutral `ChannelLayer`/`ChannelSubscription` contract과 deterministic in-memory group subscribe/publish/unsubscribe backend를 추가했다. callback failure isolation, idempotent unsubscribe, invalid input validation을 회귀 테스트로 검증했다.
- [-] **P3-03 distributed channel integration** — Redis/Valkey cross-process fan-out과 backpressure·ordering·reconnect 운영 정책은 외부 adapter와 live 환경 검증이 필요하다. WebSocket session lifecycle 자동 구독/해제는 P3-04에서 완료했다.
- [x] **P3-04 WebSocket channel lifecycle binding** — `bindWebSocketSession`이 channel message를 adapter-owned `WebSocketSession.send`로 전달하고, 원래 close callback을 보존·복원하며 session close 시 subscription을 idempotent하게 해제한다. send/close/cleanup contract를 회귀 테스트로 검증했다.
- [x] **P3-05 external channel adapter bridge** — `CallbackChannelLayer`가 broker-owned subscribe/unsubscribe/publish callback을 `ChannelLayer` virtual contract로 연결한다. Redis/Valkey protocol과 운영 lifecycle은 adapter 소유로 유지하면서 fake backend 위임 contract를 회귀 테스트로 검증했다.
- [x] **P3-06 Redis/Valkey pub/sub RESP codec** — `PUBLISH`·`SUBSCRIBE`·`UNSUBSCRIBE` 명령 encoder와 `message`·`subscribe`·`unsubscribe` event parser를 추가하고, exact shape·channel validation·trailing bytes·malformed frame 회귀 테스트를 통과시켰다.
- [-] **P3-07 Redis/Valkey live channel transport** — reconnect·ordering·backpressure 정책과 실제 cross-process fan-out live evidence는 Redis/Valkey 서비스 환경에서 후속 구현·검증한다. Dedicated async subscription socket은 P3-09에서 완료했다.
- [x] **P3-08 Redis publish adapter** — `RedisValkeyRespClient`가 `PUBLISH` command를 실행하고 subscriber count integer response를 strict하게 검증한다. subscription socket state는 별도 async adapter가 소유한다.
- [x] **P3-09 async Redis subscription adapter** — dedicated `AsyncSocket` subscription client가 RESP frame coalescing, subscribe/unsubscribe acknowledgement, local subscriber delivery, idempotent close를 loopback TCP fixture로 검증한다. reconnect·backpressure 정책과 Redis production live evidence는 남긴다.
- [x] **P3-10 Redis subscription reconnect** — 원격 socket 단절 뒤 reader 종료를 기다리고 새 AsyncSocket에 연결해 active channel을 재구독하는 명시적 one-attempt `reconnect` API를 추가했다. 두 연결 loopback fixture로 재구독과 두 번째 message delivery를 검증했다.
- [-] **P3-11 Redis channel delivery policy** — exponential retry orchestration, ordering·backpressure, Redis service 기반 cross-process fan-out과 production live evidence는 후속 운영 범위다.
- [x] **P3-12 Redis reconnect retry/backoff** — one-attempt reconnect 위에 maxAttempts·initialDelay·maxDelay를 검증하는 bounded exponential backoff orchestration을 추가하고, 성공 attempt 번호와 invalid policy를 loopback fixture로 검증했다.
- [-] **P3-13 Redis channel delivery policy** — ordering·backpressure, Redis service 기반 cross-process fan-out과 production live evidence는 후속 운영 범위다.
- [x] **P3-14 Redis ordered delivery** — subscription reader가 한 connection의 message callback을 순차적으로 await해 coalesced frame과 느린 subscriber에서도 message ordering을 보존한다는 loopback 회귀 테스트를 추가했다.
- [x] **P3-16 Redis bounded backpressure** — connection별 bounded pending queue와 `rbpCloseConnection`·`rbpDropNewest`·`rbpDropOldest` overflow policy, dropped message counter를 추가하고 느린 subscriber loopback 회귀 테스트로 검증했다.
- [x] **P3-17 Redis cross-process fan-out** — 실제 Redis 7.2.15 서비스에서 별도 OS worker 2개를 실행해 readiness, `ChannelLayer` payload delivery, subscriber count와 graceful shutdown exit를 검증했다. rolling deployment runbook은 별도 후속 항목으로 남긴다.
- [x] **P3-18 Redis service fan-out baseline** — 실제 Redis 7.2.15 서비스에서 독립 subscription socket 2개와 publisher를 연결해 동일 payload fan-out, subscriber count, delivery timeout을 `redisLive` contract로 검증했다. 별도 OS worker fan-out은 P3-17에서 검증했다.
- [x] **P3-19 Redis ChannelLayer adapter** — `RedisChannelLayer`가 `ChannelLayer`의 async subscribe/unsubscribe 확장점과 non-blocking publish socket을 소유하고, length-delimited WebSocket message envelope를 통해 실제 Redis service fan-out을 연결한다. rolling shutdown runbook은 P3-21에 남긴다.
- [x] **P3-20 Redis ChannelLayer lifecycle** — `reconnectWithRetry`가 active group을 재구독하고 `shutdown`이 UNSUBSCRIBE acknowledgement를 drain한 뒤 socket을 닫도록 구현했으며, slow broker loopback과 Redis 7.2.15 live contract로 검증했다. rolling deployment runbook은 P3-21에 남긴다.
- [-] **P3-21 Redis rolling deployment runbook** — worker drain 순서, bounded reconnect budget, readiness/liveness probe, rollback 절차와 repeatable evidence 명령을 `docs/operations-guide.md`에 문서화했다. 실제 staging rollout의 readiness transition·process exit·rollback evidence 수집은 외부 환경에서 남아 있다.
- [x] **P3-22 template loop metadata** — 반복문 렌더링에 request-local `loop.index`/`index0`/`first`/`last`/`length`를 주입하고, nested loop shadowing 및 접근성 목록 렌더링 계약 테스트를 추가했다. parser와 renderer의 책임은 유지하며 metadata는 현재 loop context에만 존재한다.
- [x] **P3-23 OpenAPI UI script boundary** — Swagger UI bootstrap의 caller-controlled `specUrl`을 JSON 직렬화 후 HTML-significant code point(`<> & U+2028/U+2029`)를 JavaScript Unicode escape로 변환하고, script 종료 시퀀스 삽입 회귀 테스트를 추가했다. ReDoc attribute escaping과 UI route 계약은 기존 경계를 유지한다.
- [x] **P3-24 SSE field injection boundary** — SSE `event`/`id` metadata를 single-line field로 검증해 CR/LF field injection을 fail-fast하고, multiline `data` framing은 유지하는 회귀 테스트를 추가했다.
- [x] **P3-25 WebSocket close frame boundary** — RFC 6455 허용 close code와 125-byte control frame limit에 맞춘 123-byte reason 검증을 core 생성자에 추가하고 reserved/invalid code·oversized reason 회귀 테스트를 고정했다.
- [x] **P3-26 WebSocket close reason UTF-8 boundary** — close reason을 표준 `validateUtf8`로 검증해 malformed UTF-8을 거부하고, 정상 Unicode reason과 invalid byte 회귀 테스트를 추가했다.

### 2026-08-05 release artifact manifest

- [x] **P0-08 release artifact manifest boundary** — `ReleaseArtifact` 목록을 path 순서로 정렬해 deterministic `path=...`/`sha256=...` manifest로 렌더링·파일 출력하는 순수 contract와 실제 파일에서 checksum을 계산하는 `collectReleaseArtifacts`/`writeArtifactManifestForFiles` 경계를 추가했다. 잘못된 path·SHA-256 metadata·누락 파일·중복 artifact를 fail fast하는 회귀 테스트를 연결했으며, 실제 Linux/Windows/macOS runner evidence는 외부 release pipeline 범위로 남긴다.
- [x] **P2-08 template adapter boundary** — framework-neutral `TemplateAdapter.renderTemplate` protocol과 내장 `TemplateEngineAdapter` wrapper, 외부 engine callback adapter를 추가하고 `Application.configureTemplateAdapter`/`renderTemplateResponse`로 공통 HTML response 경계에 연결했다. 내장·외부 callback render와 nil configuration failure를 contract test로 검증했다.

### 2026-08-05 기반선 증거 정합화

- [x] **P0-09 core foundation evidence** — 상세 implementation plan의 계약 우선·단일 메타데이터 원천·명시적 실행 경계·Prologue 비종속 원칙과 Phase 0 Application/config/request-response/router/middleware/lifecycle/error 계약을 현재 public module 및 contract test 증거에 맞춰 체크했다. 기능별 DoD, OS/Nim matrix, staging TLS와 production live evidence는 외부 검증 범위로 남긴다.

### 2026-08-05 macOS release matrix baseline

- [x] GitHub Actions에 Nim 2.2.4 `macos-latest` runner, Homebrew `libpq` 설치와 macOS 전용 `shasum` release checksum 경계를 추가하고 workflow 문서 계약 테스트를 연결했다.
- [ ] 실제 GitHub macOS runner의 test·verify·check·build와 artifact upload 성공 로그는 외부 CI 실행 후 최종 체크한다.

### 2026-08-05 plan checklist validation

- [x] `validatePlanChecklist`가 `plan.md`의 우선순위·완료 판정 section, `[x]`/`[-]`/`[ ]` marker와 빈 항목을 `nimble docsCheck`에서 검증하도록 추가했다.

### 2026-08-05 HTTPS deployment evidence baseline

- [x] `HttpsDeploymentEvidence`와 `validateHttpsDeploymentEvidence`로 HTTPS endpoint·certificate fingerprint/expiry·renewal·redirect·trusted proxy·secure cookie 증거를 공통 fail-closed contract로 검증한다.
- [x] 검증된 HTTPS evidence를 deterministic JSON artifact로 저장하는 `renderHttpsDeploymentEvidence`/`writeHttpsDeploymentEvidence` 경계를 추가했다.
- [ ] 실제 staging 인증서 체인과 renewal 자동화 성공 로그는 외부 배포 환경에서 수집한다.

### 2026-08-05 Redis channel delivery policy

- [x] `RedisChannelDeliveryPolicy`가 pending queue, overflow policy, reconnect attempt/delay budget과 ordered delivery invariant를 하나의 검증 가능한 value contract로 소유한다.
- [x] policy 기반 `RedisPubSubClient`/`RedisChannelLayer` 생성 경계와 `reconnectWithPolicy`를 추가하고, 기본값·client/layer wiring·잘못된 경계값을 회귀 테스트로 검증했다.
- [-] 실제 Redis/Valkey cross-process fan-out과 production reconnect/backpressure 운영 증거는 서비스·배포 환경에서 계속 수집한다.

### 2026-08-05 Redis channel delivery observability

- [x] `RedisChannelDeliverySnapshot`이 수신·성공 전달·callback 실패·drop·reconnect 시도/성공·connection failure를 value snapshot으로 노출한다.
- [x] loopback reconnect/backpressure/callback failure 테스트가 snapshot 수치를 검증해 운영 정책과 실제 adapter 동작의 차이를 조기에 감지한다.
- [-] snapshot을 production metrics sink와 staging rollout evidence에 연결하는 작업은 외부 운영 환경에서 계속한다.

### 2026-08-05 Redis channel metrics renderer

- [x] `redisChannelPrometheusMetrics`가 snapshot counters를 deterministic Prometheus exposition text로 렌더링하고 metric namespace와 음수 counter를 fail-fast 검증한다.
- [x] renderer의 정상 출력과 잘못된 namespace/counter 회귀 테스트를 추가해 adapter를 특정 metrics vendor에 결합하지 않았다.
- [-] 실제 metrics endpoint wiring과 production scrape/alert evidence는 application deployment 환경에서 계속한다.

### 2026-08-05 Observability metrics provider wiring

- [x] `Observability`가 `MetricsProvider` 등록 경계를 소유하고, nil provider를 구성 단계에서 거부한다.
- [x] `prometheusMetrics`와 `metricsResponse`가 application-owned provider output을 newline-safe하게 조합해 Redis channel 등 선택적 adapter metric을 같은 endpoint에서 노출한다.
- [-] 실제 deployment의 scrape 설정·alert rule·production metrics evidence는 application 운영 환경에서 계속한다.

### 2026-08-05 Redis metrics composition boundary

- [x] `RedisChannelLayer.deliverySnapshot`과 `registerRedisChannelMetrics`가 adapter snapshot을 application-owned `Observability` provider로 연결한다.
- [x] 네트워크 연결 없이 layer wiring과 공통 Prometheus endpoint 노출을 검증하는 회귀 테스트를 추가했다.
- [-] 실제 Redis metrics scrape/alert rule과 production endpoint 운영 증거는 배포 환경에서 계속한다.

### 2026-08-05 deployment recipes and macOS CI bootstrap

- [x] `.github/workflows/ci.yml`의 cross-platform matrix가 Linux용 Nim archive를 macOS에 재사용하지 않고, runner OS별 `linux_x64`/`macosx_x64` archive를 설치하도록 분리했다. `nimble docsCheck`의 workflow 계약 테스트로 이 경계를 고정했다.
- [ ] 실제 GitHub macOS runner의 test·verify·check·build와 artifact upload 성공 로그는 외부 CI 실행 후 최종 체크한다.

- [x] `deploy/Dockerfile`이 Nim 2.2.4 multi-stage build, compiler 없는 non-root runtime, SIGTERM 경계를 제공한다.
- [x] `deploy/docker-compose.yml`, `deploy/nginx.conf`, `deploy/mahanaim.service`와 `docs/deployment-recipes.md`가 health/readiness, TLS reverse proxy, WebSocket forwarding, graceful shutdown 운영 절차를 고정한다.

### 2026-08-05 concurrent password benchmark

- [x] `password_hash_benchmark`에 독립 worker process 기반 `--concurrency=N` 측정을 추가하고 각 worker의 hash/verify 검증을 유지했다.
- [x] benchmark 실행 경계와 운영 사용법을 `tests/test_docs_contract.nim`, `docs/operations-guide.md`에 연결했다. 저비용 Windows smoke(`bcrypt`, `work-factor=4`, `samples=1`, `concurrency=2`)가 통과했다.
- [-] 실제 production benchmark, concurrent memory/login load, cost 확정과 rollout evidence는 배포 환경에서 후속 검증한다.

### 2026-08-05 command/admin lifecycle boundary

- [x] 상세 구현계획서의 CLI, Prologue/JSON/TOML, test client, template adapter 상태를 실제 구현 증거와 일치시켰고, native worker 강제 종료는 안전한 backend API 전까지 미지원으로 명시했다.

- [x] `BackgroundJobQueue`와 `ExternalDurableJobStore`의 repository-owned contract를 상세 계획에서 구현 상태로 분리하고, 외부 queue provider protocol·visibility timeout·ack 운영 검증은 application-owned 범위로 명시했다.

- [x] database pool/template/migration/seed/durable-job/admin provisioning 설정도 startup transition을 포함한 pre-startup configuration window로 통합하고 regression test를 추가했다.

- [x] model metadata, DI providers, serialization codec, storage adapter와 auth backend 등록도 동일한 pre-startup registration window로 통합하고 late mutation 회귀 테스트를 추가했다.

- [x] route, grouped route, WebSocket route, global middleware와 error handler도 동일한 pre-startup registration window를 사용하도록 통합하고, 실행 후 mutation 회귀 테스트를 추가했다.

- [x] `onStartup`과 `onShutdown`도 startup 전 등록만 허용하고, hook 내부 또는 실행 후 lifecycle 순서를 변경하는 late registration을 거부한다. ordered/idempotent lifecycle 테스트로 경계를 검증했다.

- [x] `use(plugin)`과 manifest plugin 등록도 startup 전용 lifecycle boundary를 공유하고, startup transition 및 실행 이후 등록을 거부한다. route·middleware·service surface의 late mutation을 회귀 테스트로 검증했다.

- [-] 실제 application entrypoint build, certificate/secret injection과 staging rollout evidence는 application-owned 배포 환경에서 계속한다.
- [x] `registerCommand`와 `registerAdminExtension`은 application startup 전 등록만 허용하고, startup transition 중에도 late mutation을 거부한다. lifecycle contract 회귀 테스트로 command surface와 admin extension registration의 불변 경계를 검증했다.
- [ ] 실제 GitHub macOS runner와 staging deployment의 외부 evidence 수집은 배포 환경에서 계속한다.

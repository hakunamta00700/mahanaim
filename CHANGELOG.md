# Changelog

## Unreleased

- class-based `Controller.handle` virtual contract와 `addControllerRoute` bridge를 추가해 controller action dispatch와 Application route/middleware lifecycle을 분리했다.
- 구현계획의 local adapter baseline과 외부 운영 증거를 재분류하고, 문서 계약 테스트로 object storage·WebSocket·OpenAPI UI 상태를 고정했다.
- `ReleaseArtifact` 목록에서 deterministic SHA-256 manifest를 생성·저장하는 `renderArtifactManifest`와 `writeArtifactManifest` 경계를 추가했다.
- `TemplateAdapter` protocol과 내장 engine wrapper·외부 callback adapter를 추가해 alternate template engine 교체 경계를 제공했다.
- Application이 선택된 template adapter를 공통 HTML response로 연결하도록 `configureTemplateAdapter`와 `renderTemplateResponse`를 추가했다.
- 상세 구현계획의 핵심 기반선 체크박스를 public contract·회귀 테스트 증거와 정합화하고, P0-09 외부 검증 범위를 명시했다.
- GitHub Actions cross-platform release matrix에 macOS Nim 2.2.4 runner와 Homebrew `libpq`·`shasum` 경계를 추가했다.
- release artifact 파일 목록에서 checksum을 계산해 deterministic manifest를 생성하는 `collectReleaseArtifacts`와 `writeArtifactManifestForFiles`를 추가했다.
- cross-platform CI release job이 `nimble releaseManifest`로 artifact manifest를 생성해 checksum artifact와 함께 업로드하도록 연결했다.
- `validatePlanChecklist`를 추가해 `plan.md`의 section, checkbox 상태와 빈 항목을 `nimble docsCheck`에서 검증하도록 했다.
- `HttpsDeploymentEvidence`와 fail-closed validator를 추가해 staging HTTPS 인증서·proxy·redirect·secure-cookie evidence의 공통 형식을 고정했다.
- 검증된 HTTPS deployment evidence를 deterministic JSON artifact로 저장하는 render/write API를 추가했다.
- Redis channel delivery 정책을 bounded queue·overflow·reconnect budget·ordered delivery를 묶는 공통 value contract로 정리했다.
- Redis subscription의 수신·전달·drop·실패·reconnect 상태를 읽기 전용 `RedisChannelDeliverySnapshot`으로 관측할 수 있게 했다.
- Redis channel delivery snapshot을 deterministic Prometheus exposition text로 렌더링하는 vendor-neutral API를 추가했다.
- `Observability`에 application-owned `MetricsProvider` 등록 경계를 추가해 adapter metric을 공통 Prometheus endpoint에 조합할 수 있게 했다.
- WebSocket close reason의 malformed UTF-8을 공통 core에서 거부하고 정상 Unicode reason을 허용하는 계약 테스트를 추가했다.
- WebSocket close message의 RFC 6455 code 범위와 123-byte reason 한계를 core에서 검증하고 reserved code·oversized reason 회귀 테스트를 추가했다.
- SSE `event`/`id` metadata의 CR/LF field injection을 거부하고 multiline `data` framing을 보존하는 계약 테스트를 추가했다.
- Swagger UI bootstrap의 외부 schema URL을 HTML-significant code point까지 JavaScript Unicode escape 처리하고 `</script>` 삽입 회귀 테스트를 추가했다.
- template loop에 request-local `loop.index`·`index0`·`first`·`last`·`length` metadata를 추가하고 nested-loop shadowing 및 접근성 목록 렌더링 회귀 테스트를 추가했다.
- framework-neutral `ChannelLayer`/`ChannelSubscription`과 in-memory group broadcast backend를 추가하고, subscribe/publish/unsubscribe·idempotent cleanup·subscriber failure isolation 회귀 테스트를 추가했다. Redis/Valkey cross-process fan-out과 WebSocket session lifecycle 자동 연동은 후속 adapter 범위다.
- executor의 `maxQueuedJobs`를 `AppConfig` 및 `MAHANAIM_EXECUTOR_MAX_QUEUED_JOBS` 환경 변수로 설정할 수 있도록 연결하고 음수 설정을 pre-flight에서 거부한다.
- `MAHANAIM_VALUE_<KEY>=<JSON>` 환경변수로 배열·객체 structured config를 주입하고 file provider보다 높은 precedence 및 malformed JSON/type validation 경계를 추가했다.
- 상세 구현 계획의 macro schema, route validation, model metadata, observability, WebSocket/Beast gate 상태를 현재 코드·테스트 증거와 일치하도록 감사했다.
- deterministic router benchmark를 `nimble routerBenchmark` gate로 추가해 route-index 변경을 반복 측정할 수 있도록 했다.
- router index를 static segment run을 압축하는 radix edge와 first-segment lookup으로 개선하고 precedence 회귀 테스트를 추가했다.
- S3-compatible object transport에 application-owned callback을 감싸는 bounded retry decorator와 성공·최종 실패 contract test를 추가했다.
- Prologue와 독립적인 direct httpx HTTP/WebSocket deployment adapter와 Windows/Linux compile·settings validation gate를 추가했다.
- WebSocket adapter에 fragmented text continuation 재조립과 interleaved ping/pong 처리를 추가하고 loopback wire 회귀 테스트를 확장했다.
- template engine에 `if/elif/else/endif` 조건 분기 AST와 short-circuit 렌더링, true/false branch 회귀 테스트를 추가했다.
- template engine에 빈 collection의 empty-state를 위한 `for/else/endfor` 분기와 항목 존재·부재 회귀 테스트를 추가했다.
- OpenAPI registry에서 typed request/response interface와 path/query encoding을 포함한 deterministic TypeScript `fetch` client artifact를 생성하는 `typescriptClient` 및 `openapi-ts [PATH]` CLI를 추가했다.
- buffered response의 strong `ETag`와 `If-None-Match` weak comparison을 공통 dispatch 경계에 추가하고, 일치하는 `GET`/`HEAD`를 304로 반환하도록 했다. stream/SSE/WebSocket은 제외한다.
- executor에 active worker와 waiting queue를 분리한 `maxQueuedJobs` bounded admission 및 `executor_queue_full` 503 contract를 추가했다.

- `TemplateRenderContext`에 request-owned locale formatter snapshot과 자동 `format_decimal`/`format_datetime` helper를 추가하고 unconfigured/invalid input/reserved name 경계를 회귀 테스트했다.
- `EmailTransport`에 validated RFC 5322 wire를 application-owned SMTP/API/outbox로 넘기는 callback adapter와 회귀 테스트를 추가했다.
- P2 운영 도구에 mailbox/header injection/recipient/content-type 경계를 검증하는 RFC 5322 simple-part email serializer와 framework-neutral `EmailTransport`/in-memory adapter를 추가했다. SMTP socket·credential·retry는 application-owned adapter 범위다.
- P2 syndication contract에 XML escaping·absolute URL·필수 identity 검증을 포함한 framework-neutral Atom 1.0 feed/entry renderer와 회귀 테스트를 추가했다. email backend는 application-owned transport 범위로 남긴다.
- `ExternalDurableJobStore`의 close callback을 idempotent하게 만들고 close 이후 enqueue/claim/complete/release/recover callback 재사용을 `ValueError`로 차단하는 lifecycle contract와 회귀 테스트를 추가했다.
- SQLite durable job store의 `complete`·`release`·`recoverProcessing`가 close 이후 db connector assertion을 노출하지 않고 명시적 `ValueError`를 반환하도록 보강하고 shutdown race 회귀 테스트를 추가했다.
- P0 `REQ-TEST-002`를 `checkApplication`의 config/route/model/migration/security/execution 검사와 embedding/standalone CLI 공통 `CheckReport` contract 테스트에 맞춰 완료로 갱신했다.
- P1 migration 요구사항 표를 SQLite/PostgreSQL migration runner·provider·CLI·metadata schema contract와 PostgreSQL live evidence에 맞춰 완료로 갱신하고, provider 선택/CI wiring은 application-owned extension으로 분리했다.
- P1 query/API 요구사항 표에서 pagination·cursor·filter/sort/field-selection·aggregate·relation loading을 실제 contract 테스트가 증명하는 구현 완료 범위로 갱신했다.
- P2 운영 계획에서 rate-limit·SQLite durable queue·background job의 로컬 contract/CLI/복구 범위와 외부 Redis eviction·queue provider 운영 검증 범위를 분리해 체크리스트 상태를 정합화했다.
- P0 보안 기본값 계획에서 timeout·rate limit·request size·secure cookie·config scalar validation·공개 host warning의 로컬 구현 범위와 운영 staging TLS 증거 범위를 분리해 체크리스트 상태를 정합화했다.
- P1 typed response/OpenAPI 계획을 구현 완료 범위와 명시적 typed handler가 필요한 DTO body schema 자동 추론 보류 범위로 분리해 체크리스트 상태를 정합화했다.
- Windows amd64/Nim 2.2.4 개발 호스트에서 Argon2id 기본 정책과 bcrypt work factor 12의 samples=5 hash/verify baseline을 측정해 운영 문서에 기록했다. 해당 값은 production 권고값이 아니며 배포 호스트 재측정이 필요하다.
- Definition of Done 문서의 필수 섹션·체크박스 표기·검증 명령을 `validateDefinitionOfDone`로 검사하는 `nimble docsCheck` 계약과 회귀 테스트를 추가하고, `verify` 및 CI에 연결했다.
- Docker nginx 1.27.5와 Nim/Linux 2.2.4 upstream의 HTTPS wire fixture를 재실행해 HTTP→HTTPS redirect 및 reverse-proxy live contract 통과를 확인했다. 운영 staging의 공인 인증서·갱신·외부 DNS 검증은 배포 환경 범위로 남겼다.
- CI verify job에 Redis 7.2 service와 health check, `MAHANAIM_REDIS_*` 설정, `redisLiveCheck`/`redisLive` gate를 추가했다. bounded eviction 설정은 disposable CI container에서만 명시적으로 허용하고 외부 Redis 환경은 변경하지 않는다.
- JSON/TOML 설정 provider가 `environment`, `debug`, `host`, `port`, request timeout, executor capacity의 원본 scalar 타입을 공통 schema로 검증하도록 보완했다. 확장 설정 구조는 기존처럼 typed values로 보존하며 잘못된 JSON/TOML 타입 회귀 테스트를 추가했다.
- `nimble.lock`의 version·package metadata·필수 dependency·SHA-1 checksum shape를 검증하는 `validateDependencyLock` contract와 `nimble lockCheck` gate를 추가하고 `verify`에 연결했다. clean OS runner의 dependency 재설치 증거는 별도 CI matrix 범위로 남겼다.
- 생성 프로젝트가 동일한 migration 정의를 초기 SQLite 준비와 Application migration registry에 연결하고, 인증 account store/hasher 기반 admin provisioning callback을 standalone CLI에 제공하도록 보완했다. 저장소 영속화와 credential 정책은 프로젝트 소유 범위로 유지했다.
- `mahanaim new`가 생성하는 애플리케이션 모듈을 `createApp()`과 `commandLineParams()`를 공통 `runCli`에 연결하는 명시적 standalone CLI 진입점으로 만들었다. 프레임워크가 임의 프로젝트 모듈을 자동 import하지 않도록 경계를 유지하면서 migration registry/account callback wiring과 startup/shutdown lifecycle을 생성 앱에 연결했다.

- `Application.dispatch`가 request-scoped service child container를 자동 생성·정리하도록 연결했다. shutdown 시 instance는 release하지만 명시적 registration은 reopen해 post-shutdown health dispatch와 lifecycle restart 계약을 보존한다.
- 구현계획의 기존 회귀 테스트 증거를 재감사해 관계 query·migration up/down, admin query/action/layout, 권한 거부, MessagePack·storage·plugin·system check 항목의 체크 상태와 잔여 production 범위를 정리했다.
- DI service container에 명시적 child scope, dependency factory graph/cycle 검증, disposer와 Application shutdown disposal을 추가했다. application singleton과 request/task 소유권을 분리하는 contract test를 포함한다.
- Application 소유 `MigrationDatabaseProvider`를 추가해 migration CLI가 명시적 backend connection lifecycle과 command runner를 사용하도록 연결했다. 기본 SQLite와 provider-backed `db seed`를 유지하고 DSN·credential 자동 추측을 금지한다.
- PostgreSQL 16 live contract에서 serializable session의 typed `FOR UPDATE`/`FOR SHARE` row-lock 실행, commit lifecycle, 두 session 간 bounded `lock_timeout` contention을 검증하고, SQLite·aggregate lock의 fail-fast 경계를 유지했다.
- 서버 렌더링용 XML sitemap 및 RSS 2.0 renderer를 추가했다. absolute URL 검증, XML escaping, sitemap metadata, RSS channel/item 필수값 검증을 공통 contract로 제공한다.
- 실제 loopback live-server smoke test를 재사용할 수 있도록 ephemeral-port readiness와 wire 응답 정규화를 제공하는 `NetworkTestFixture`/`NetworkTestClient`를 추가했다. status·header·body와 idempotent shutdown 회귀 테스트를 포함한다.
- 서버 렌더링 흐름을 위한 bounded FIFO `FlashStore`와 기본 in-memory adapter를 추가했다. session별 격리와 consume-once semantics를 Application 기본 contract로 제공한다.
- plugin이 Application 소유 serialization codec registry, named object storage registry, ordered auth backend를 명시적으로 등록할 수 있는 확장 API를 추가했다. 중복 등록과 실제 plugin 연결 회귀 테스트를 포함했다.
- admin detail HTML 화면과 metadata 기반 edit form, URL-encoded create/update, 명시적 POST delete/redirect 흐름을 추가해 별도 SPA 없이 CRUD 화면을 사용할 수 있게 했다. JSON API와 기존 권한·감사 경계는 유지한다.
- admin list route가 기존 JSON 응답을 유지하면서 `Accept: text/html` 요청에 escaped HTML table과 신규 항목 링크를 제공하도록 확장했다. 공통 query/projection/권한 경계와 JSON·HTML 협상 회귀 테스트를 추가했다.

- 첫 수직 슬라이스 통합 계약을 추가해 SQLite metadata migration의 타입·자동 증가
  PK 보존, JSON/admin CRUD, CSRF·session·권한, OpenAPI·health·request ID·shutdown을
  하나의 Application lifecycle에서 검증한다.
- `mahanaim new` 생성 프로젝트가 SQLite metadata migration, JSON/admin CRUD,
  session·CSRF 인증, OpenAPI route collection, health/request ID/lifecycle을
  실제 생성 테스트에서 실행하도록 확장했다.
- 실제 TCP 요청이 Application의 SQLite database pool을 borrow/release하고,
  응답 후 idle 반환과 shutdown close를 보장하는 live-server 통합 계약을 추가했다.
- PostgreSQL 16 컨테이너에서 `postgresLive`를 실행해 pool/session lifecycle과
  PostgreSQL-backed HTTP·SSE·WebSocket wire contract를 실제로 통과시켰다.
- SQLite와 PostgreSQL adapter의 DML 결과가 공통 `DatabaseResult.affectedRows`로
  영향받은 행 수를 반환하도록 연결하고, SQLite 회귀 테스트와 PostgreSQL 16 live
  insert contract를 추가했다.
- HTTPS Docker wire fixture가 cold cache에서 Nim 의존성 설치·upstream 컴파일에
  필요한 bounded readiness window를 허용하도록 보완했고, nginx TLS 1.2/1.3,
  trusted proxy hop과 secure cookie live contract를 다시 통과시켰다.
- HTTPS wire fixture에 HTTP→HTTPS `301 Location` 검증을 추가해 TLS 응답과
  redirect 정책을 별도의 관찰 가능한 계약으로 분리했다.
- Windows cross-platform CI가 PostgreSQL adapter를 로드할 때 필요한
  `libpq.dll` client runtime을 명시적으로 설치하고 PATH에 연결하도록 보완했다.
- typed documented route의 request/response DTO schema가 서로 독립적인 필드
  집합을 유지하도록 회귀 검증을 강화했다.
- response variant의 `Accept` negotiation을 `Application.dispatch` 공통 경계로
  이동해 in-process client, stdlib HTTP, Prologue adapter가 동일한 406 및
  `Vary: Accept` 정책을 사용하도록 정리했다.

- Linux CI에 HTTPS reverse-proxy wire contract compile gate와 staging URL 부재 시 명시적 skip gate를 연결했다.
- `checkApplication`이 HTTPS 강제 정책에서 `allowedHosts` 미설정을 warning으로 보고하도록 연결해 reverse-proxy 운영 점검 경계를 강화했다.
- `PasswordHasher`에 Nim maintained pure bcrypt adapter를 추가하고 `$2a$`·`$2b$`·`$2y$` 검증, work-factor rotation, bcrypt benchmark output과 Windows/Linux contract gate를 연결했다.
- Beast/httpx Linux live gate와 PostgreSQL pool/session·HTTP/SSE/WebSocket live-server 계약을 추가하고, HTTP adapter가 parent socket ownership을 보존하도록 WebSocket close 경계를 수정했다.
- `authBackends` provider 목록으로 signed session cookie와 bearer token을 한 route의 공통 `AuthContext`와 route guard에 조합하도록 확장했다.
- CLI migration contract에 `db migrate` 별칭을 추가하고 standalone `admin`/`jobs` 진입점을 embedding `runCli`와 같은 application-owned 경계에 연결했다.
- Application config secret을 structured observability log record의 모든 문자열 필드에서 sink 전달 전에 재귀적으로 redaction하도록 연결했다.
- `defaultConfig`에 30초 request timeout과 `defaultSecurityPolicy`에 60초당 1000건 bounded rate limit을 활성화해 기본 실행 경계를 추가했다.
- `Request`의 adapter scheme/peer와 `SecurityPolicy.requireHttps`·`trustedProxies`를 연결해 신뢰된 reverse proxy의 forwarded scheme/host만 사용하도록 보안 경계를 추가했다.
- template engine의 marker 재검색 렌더링을 `TemplateNode` 구조형 AST parser/render 경계로 전환해 중첩 if/for/block/include, typed helper argument, quoted literal과 교차 종료 태그 검증을 일관되게 처리한다.
- PostgreSQL adapter에 migration history, transactional up/down, idempotent migrate, status와 latest rollback을 추가하고 공통 migration command contract에 연결했다.
- Redis/Valkey RESP client에 읽기 전용 `INFO server`·`CONFIG GET` compatibility probe를 추가해 vendor/version과 bounded eviction 설정을 운영 진단에서 확인하도록 했다.
- Redis/Valkey compatibility probe가 `COMMAND INFO`로 fixed-window·cache에 필요한 RESP 명령 지원 여부와 RESP2/RESP3 null 응답을 함께 진단하도록 확장했다.
- Redis/Valkey RESP client가 하나의 TCP read에 합쳐진 여러 response frame을 보존하도록 개선하고, 환경 기반 `redisLive` contract gate를 추가했다.
- Linux Nim 2.2.4 matrix에서 Redis 7.2.15와 Valkey 8.1.9의 PING·필수 command·bounded eviction·server-side TTL live contract를 통과시켰다.
- rate-limit dynamic dispatch와 Redis transport callback에 `gcsafe` 경계를 명시해 Linux C runtime build에서도 async security middleware를 컴파일하도록 정리했다.
- Docker nginx TLS 1.2/1.3과 Linux Nim 2.2.4 upstream을 연결하는 HTTPS reverse-proxy wire fixture 및 외부 endpoint용 `httpsLive` client를 추가했다.

- model macro가 `newModelCustomField(name, wireType)`로 임의 Nim custom type을 명시적 metadata/wire contract에 연결하고 자동 타입 추측을 거부하도록 확장했다.
- template engine이 명시적 `TemplateRenderContext` collection과 중첩 `{% for %}` loop를 조건문·자동 escaping과 함께 지원하도록 확장했다.
- template engine이 현재 loop context를 받아 동적으로 child collection을 제공하는 `TemplateCollectionProjection`과 nested relation 렌더링 회귀 테스트를 추가했다.
- template engine에 named/quoted/context argument를 AST 형태로 전달하는 `registerHelper`와 최종 escaping 경계를 추가했다.
- server-rendered form이 middleware의 request-scoped CSRF token을 hidden input과 동일하게 사용하도록 연결해 cookie/header double-submit 흐름을 검증했다.
- 계획 기반 framework contract, adapter 경계와 회귀 테스트를 계속 확장한다.
- SQLite adapter가 공통 `DatabaseResult`에 컬럼명과 선언 타입·runtime storage class 기반 typed scalar 및 NULL metadata를 제공하도록 확장했다.
- pre-flight `checkApplication(app)`가 Application runtime middleware에 실제 주입된 `SecurityPolicy`를 검사하도록 정합성을 보장했다.
- response content negotiation 결과에 `Vary: Accept`를 추가하고 stream/SSE/WebSocket 표현 선택 및 406 회귀 테스트를 확장했다.
- MessagePack에 chunked stream response helper와 JSON/MessagePack stream content negotiation을 추가했다.
- TemplateEngine에 deterministic locale JSON catalog directory loader를 추가하고 다중 locale·무관한 확장자·없는 디렉터리 회귀를 검증했다.
- Admin registry가 SQLite `DatabaseRepositoryResourceStore`와 실제 CRUD·audit route를 함께 사용하는 통합 회귀를 추가했다.
- embedding/standalone CLI에 등록 route 기반 OpenAPI 3.1 문서를 stdout 또는 파일로 생성하는 `openapi [PATH]` 명령을 추가했다.
- Application 소유 provisioning callback과 account adapter를 통해 `admin create-user <identifier> [subject]`를 추가하고 비밀번호 argv 노출을 피하도록 환경변수 입력을 사용한다.
- `static collect <source...> --output <path>`와 deterministic local asset manifest를 추가하고 중복·충돌·source 내부 output·symbolic link 경계를 검증한다.
- backend-neutral `ObjectStorage`/`CacheStore`, bounded in-memory adapters와 S3-compatible transport bridge를 추가하고 key traversal·prefix·TTL·eviction 경계를 검증한다.
- 공통 RESP command framing과 `RedisCacheStore`의 `GET`·`SETEX`·`SET`·`DEL` 경계를 추가하고 기존 loopback/fake 계약 테스트로 검증한다.
- observability에 vendor-neutral Prometheus text exposition과 `metricsResponse` helper를 추가하고 request/error/in-flight/readiness 지표 계약을 검증한다.
- durable job에 `ExternalDurableJobStore` callback bridge를 추가해 외부 queue의 enqueue/claim/complete/release/recover/close 상태 전이를 framework contract로 연결한다.
- model macro가 `Option[T]`를 nullable metadata와 optional input/response schema로 일관되게 투영하도록 확장했다.
- model macro가 명시적 index·constraint·relation 선언을 backend-neutral metadata에 추가하도록 확장했다.
- model macro가 `seq[T]`와 `array[N,T]`를 JSON collection metadata·input schema·OpenAPI array로 투영하고 serializer에서 배열 shape를 검증하도록 확장했다.
- serializer가 field `wireType`과 명시적 codec registry를 통해 custom JSON wire 변환을 지원하고 누락·중복 codec을 거부하도록 확장했다.
- PostgreSQL 결과를 공통 `DatabaseResult`와 column metadata로 노출하고 libpq type OID 기반 typed scalar mapping을 추가했다.
- PostgreSQL live contract에 typed metadata, filtering, grouped aggregate, one-to-many relation, DDL rollback 검증과 `postgresLiveCheck` compile gate를 연결했다.
- PostgreSQL 16 live contract에서 JSONB OID typed metadata와 명시적 custom field wire codec, serializable/repository/migration rollback 경로를 검증했다.
- PostgreSQL migration live contract에 shared command의 status/up/idempotency/schema-history/rollback과 SQLite/PostgreSQL capability matrix evidence를 연결했다.
- `new` 생성기가 `.env.example`, 안전한 `.gitignore`, health route와 실제 dispatch 테스트를 포함한 starter project를 생성하도록 확장했다.
- 릴리스 지원 범위와 외부 live gate는 [`docs/support-policy.md`](docs/support-policy.md)를 따른다.

변경 사항은 사용자 영향, migration 필요 여부, 보안 기본값 변경 여부를 함께
기록한다.
- WebSocket channel binding을 추가해 group broadcast를 adapter-owned `send` callback으로 전달하고, 원래 close callback 복원과 session 종료 시 idempotent subscription cleanup을 보장한다.
- 외부 broker를 코어에 결합하지 않는 `CallbackChannelLayer` bridge를 추가해 subscribe/unsubscribe/publish callback을 공통 channel contract로 위임하고, fake backend contract test를 추가했다.
- Redis/Valkey pub/sub RESP2 `PUBLISH`·`SUBSCRIBE`·`UNSUBSCRIBE` encoder와 message/subscribe/unsubscribe event parser를 추가하고 malformed frame 방어 회귀 테스트를 추가했다. 실제 async subscription socket과 cross-process live fan-out은 후속 범위다.
- 기존 Redis/Valkey RESP client에 `PUBLISH` 실행과 subscriber count strict integer response parser를 추가했다. Redis subscription socket과 async receive loop는 별도 adapter 경계로 유지한다.
- dedicated async Redis/Valkey pub/sub subscription client를 추가해 long-lived socket, coalesced RESP frame buffering, subscribe/unsubscribe ack, callback delivery와 close lifecycle을 loopback TCP로 검증했다. reconnect·backpressure와 production cross-process wiring은 후속 범위다.
- Redis async subscription client에 explicit reconnect를 추가해 원격 socket 단절 후 active channel을 재구독하고 두 번째 message를 전달하도록 했다. retry/backoff orchestration과 ordering·backpressure·production cross-process 검증은 후속 범위다.
- Redis subscription reconnect에 bounded exponential backoff와 max attempt/delay validation을 추가하고, 실패 후 재시도 성공 attempt를 loopback fixture로 검증했다. ordering·backpressure와 production cross-process fan-out은 후속 범위다.
- Redis async subscription reader의 per-connection ordered delivery를 slow subscriber와 coalesced frames loopback 테스트로 검증했다. bounded queue/overflow backpressure와 production cross-process fan-out은 후속 범위다.
- Redis async subscription client에 connection별 bounded pending queue와 close/drop-newest/drop-oldest overflow policy, dropped message counter를 추가하고 느린 subscriber loopback 회귀 테스트로 검증했다. 실제 Redis service 기반 cross-process fan-out은 후속 범위다.
- `redisLive` 계약에 실제 Redis 서비스의 독립 subscription 연결 2개와 publisher를 사용하는 multi-connection fan-out 검증을 추가했다. Redis 7.2.15 disposable container에서 subscriber count 2와 양쪽 payload delivery를 통과시켰으며, 별도 프로세스 `ChannelLayer` wiring은 후속 범위다.
- `RedisChannelLayer` adapter를 추가해 async subscription acknowledgement, bounded Redis pub/sub delivery, non-blocking publish socket과 WebSocket message envelope를 framework-neutral `ChannelLayer`에 연결했다. Redis 7.2.15 live contract에서 두 adapter instance의 fan-out을 검증했으며 별도 OS 프로세스 운영 증거는 후속 범위다.
- `RedisChannelLayer`에 active group 재구독을 수행하는 bounded `reconnectWithRetry`와 UNSUBSCRIBE acknowledgement를 drain하는 graceful `shutdown`을 추가하고 loopback/live lifecycle contract를 검증했다. 별도 OS 프로세스 rolling deployment evidence는 후속 범위다.
- `redisLive`가 별도 OS worker 2개를 실행해 Redis 7.2.15 cross-process `ChannelLayer` fan-out, readiness, payload delivery와 graceful shutdown exit를 검증하도록 확장했다. 실제 rolling deployment runbook은 후속 범위다.
- Redis ChannelLayer rolling deployment runbook을 추가해 drain 순서, bounded reconnect budget, readiness/liveness gate, rollback 절차와 repeatable evidence 명령을 고정했다. 실제 staging rollout 증거는 외부 환경 범위로 남겼다.

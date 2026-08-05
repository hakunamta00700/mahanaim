# Changelog

## Unreleased

- `mahanaim new`가 생성하는 애플리케이션 모듈을 `createApp()`과 `commandLineParams()`를 공통 `runCli`에 연결하는 명시적 standalone CLI 진입점으로 만들었다. 프레임워크가 임의 프로젝트 모듈을 자동 import하지 않도록 경계를 유지했으며, migration provider/account callback 자동 구성은 후속 범위로 기록했다.

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

# Changelog

## Unreleased

- `authBackends` provider 목록으로 signed session cookie와 bearer token을 한 route의 공통 `AuthContext`와 route guard에 조합하도록 확장했다.
- CLI migration contract에 `db migrate` 별칭을 추가하고 standalone `admin`/`jobs` 진입점을 embedding `runCli`와 같은 application-owned 경계에 연결했다.
- Application config secret을 structured observability log record의 모든 문자열 필드에서 sink 전달 전에 재귀적으로 redaction하도록 연결했다.

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
- `new` 생성기가 `.env.example`, 안전한 `.gitignore`, health route와 실제 dispatch 테스트를 포함한 starter project를 생성하도록 확장했다.
- 릴리스 지원 범위와 외부 live gate는 [`docs/support-policy.md`](docs/support-policy.md)를 따른다.

변경 사항은 사용자 영향, migration 필요 여부, 보안 기본값 변경 여부를 함께
기록한다.

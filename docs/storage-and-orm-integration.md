# Storage and ORM integration patterns

이 문서는 저장소와 ORM을 애플리케이션에 연결할 때 지켜야 하는
framework-neutral 경계를 설명한다. Mahanaim core는 파일 시스템, Redis/Valkey,
S3 SDK 또는 특정 외부 ORM을 직접 소유하지 않는다. 애플리케이션은 core 계약을
구현하는 adapter를 구성하고, adapter의 수명·자격 증명·운영 정책을 소유한다.

## Framework-owned contract

저장소와 데이터베이스의 공통 계약은 다음처럼 나뉜다.

| 목적 | core 계약 | adapter 책임 | 애플리케이션 책임 |
| --- | --- | --- | --- |
| 파일·오브젝트 | `ObjectStorage` | key 검증을 보존하면서 put/get/delete 수행 | bucket, prefix, ACL, signed URL, retry와 credential |
| 캐시 | `CacheStore` | missing value, TTL, set/delete 의미 보존 | namespace, eviction capacity, 장애 시 fail-open/closed 정책 |
| 관계형 데이터 | `DatabaseAdapter` + `DatabaseRepository` | SQL dialect, connection, transaction, row/result mapping | migration registry, pool 수명, query 정책과 배포 schema |
| 외부 ORM | 명시적 repository/adapter bridge | ORM query와 `DatabaseAdapter` 의미 변환 | ORM session/unit-of-work와 entity lifecycle |

핵심 원칙은 다음과 같다.

- HTTP handler와 domain service는 provider client나 ORM session을 직접 생성하지 않는다.
- `Application`은 등록과 lifecycle 경계를 소유하고, request/task scope가 adapter를
  빌리고 반환하는 시점을 명시한다.
- 외부 provider가 제공하지 않는 capability는 조용히 흉내 내지 말고 명시적으로
  실패시킨다. 특히 transaction, TTL, ordering, retry의 의미를 adapter마다 다르게
  바꾸지 않는다.
- adapter가 반환하는 오류는 key, credential, timeout, unavailable, unsupported를
  구분할 수 있어야 하며, 보안상 민감한 값은 오류·로그·metrics에 포함하지 않는다.

## ObjectStorage and CacheStore

### Local filesystem or in-memory object storage

개발·테스트에서는 `newInMemoryObjectStorage()`를 사용해 deterministic한 fixture를
만든다. 실제 파일 저장 adapter를 추가할 때도 object key는 경로가 아니라 이름으로
취급해야 한다. 빈 key, 절대 경로, `.`·`..` segment, NUL과 platform separator를
거부하고 web root 밖의 명시적 base directory로만 변환한다.

```nim
let uploads = newInMemoryObjectStorage()
app.registerStorage("uploads", uploads)
let stored = uploads.putObject("avatars/user-42.txt", body,
  "text/plain; charset=utf-8")
```

파일 adapter는 같은 `ObjectStorage` 계약을 사용하되 다음 정책을 application
configuration으로 받는다.

1. base directory는 startup 전에 resolve하고 writable 여부를 확인한다.
2. upload size, MIME allow-list, overwrite 정책을 저장 전에 검사한다.
3. 응답에는 내부 파일 경로를 노출하지 않고 logical key 또는 signed URL만 사용한다.
4. 삭제와 정리는 idempotent하게 만들고, 실패 시 원인을 보존한 채 재시도 가능하게 한다.

S3-compatible adapter는 `S3ObjectTransport` 같은 application-owned callback을 통해
signing, endpoint, retry/backoff를 주입한다. core가 access key나 SDK 타입을 알게
만들지 않는다. provider별 eventual consistency와 multipart upload는 별도의 adapter
contract와 live test가 필요하다.

### Cache

`CacheStore`는 `get`의 missing/expired 의미, non-negative TTL, `set`, `delete`를
공통으로 제공한다. in-memory cache는 단위 테스트와 단일 프로세스 개발용이며,
Redis/Valkey cache는 여러 인스턴스가 공유해야 할 때 선택한다.

- key에는 application 또는 tenant namespace를 붙인다.
- cache hit를 correctness의 유일한 원천으로 사용하지 않는다.
- Redis/Valkey 장애 시 요청을 fail-open할지 fail-closed할지 기능별로 명시한다.
- bounded capacity와 TTL은 운영 값으로 설정하고, 무제한 key cardinality를 허용하지
  않는다.
- 분산 rate-limit처럼 원자성이 필요한 기능은 일반 cache adapter가 아닌 해당
  capability contract를 사용한다.

## DatabaseRepository and external ORM integration

`DatabaseRepository`는 `ModelMetadata`와 backend-neutral `DatabaseAdapter` 사이의
translation layer다. repository는 HTTP status, template rendering, 인증 결정을
소유하지 않는다. 이 분리는 SQL backend와 외부 ORM을 교체해도 route/application
lifecycle이 변하지 않게 한다.

### Recommended bridge

외부 ORM을 연결할 때는 다음 세 계층을 유지한다.

1. **ORM adapter**: 외부 ORM의 query/session/entity를 `DatabaseAdapter` 또는
   명시적 repository result로 변환한다. parameter binding과 transaction 경계를
   여기서 검증한다.
2. **repository**: `ModelMetadata`, `ResourceRow`, filter, pagination, aggregate의
   framework 의미를 소유한다. ORM entity를 HTTP response로 바로 반환하지 않는다.
3. **application service/route**: request validation, authorization, serialization,
   response status와 scope disposal을 소유한다.

ORM integration은 core에 다음 API를 추가하는 방식으로 시작하지 않는다.

```nim
type ExternalOrmBridge = ref object
  ## 외부 ORM session은 request/task scope가 소유한다.
  database: DatabaseAdapter
  closeSession: proc() {.gcsafe.}
```

대신 실제 ORM의 session과 query를 감싸는 별도 module에서 bridge를 만들고,
application startup에서 명시적으로 등록한다. entity lazy loading은 response
serialization 이후에도 session이 살아 있다고 가정하지 말고, 필요한 projection을
repository 경계 안에서 materialize한다.

### Transaction and lifecycle rules

- request마다 session을 새로 빌리고 response 또는 예외 뒤 반드시 반환한다.
- mutation은 하나의 명시적 transaction 안에서 수행하고, 성공 시 commit·예외 시
  rollback한다.
- ORM이 savepoint, isolation 또는 affected-row count를 지원하지 않으면 capability를
  선언하고 해당 작업을 fail fast한다.
- `Application.startup` 이후 repository/adapter 등록을 변경하지 않는다.
- shutdown에서는 새 작업을 받지 않고 in-flight scope를 drain한 뒤 pool/session과
  provider client를 닫는다.

### Raw SQL and multi-database routing

`newRawSqlQuery(sql, parameters)`는 query builder가 표현하지 않는 dialect 기능을
위한 명시적 escape hatch다. SQL text는 application-owned이며 값은 반드시
`SqlValue` parameter로 바인딩한다. 문자열 보간 helper나 다중 statement는 제공하지
않는다. `executeRaw`는 `DatabaseResult` metadata와 affected-row count를 그대로
반환한다.

read/write 분리는 `DatabaseRouter`에 각 역할을 명시적으로 등록할 때만 사용할 수
있다. 누락된 role은 default adapter로 fallback하지 않고 `Database routing is
unsupported` 오류를 반환한다. transaction은 한 adapter connection 안에서만
수행하며 cross-database transaction은 first-party 지원 범위가 아니다.

## Adapter contract test matrix

새 adapter는 최소한 다음 테스트를 같은 의미로 공유해야 한다.

| 경계 | 필수 회귀 |
| --- | --- |
| object storage | safe key, put/get/delete, missing object, content type, overwrite |
| cache | hit/miss, expiry, negative TTL rejection, delete, bounded eviction |
| database/ORM | bind parameter, CRUD mapping, commit/rollback, isolation capability, close |
| 운영 오류 | timeout, unavailable, retry limit, redaction, unsupported capability |

로컬 단위 테스트가 통과해도 외부 provider의 signing, cross-process consistency,
TLS, credential rotation과 production latency를 증명하지는 않는다. 그런 항목은
`redisLive`, PostgreSQL live gate 또는 애플리케이션 소유 staging runbook에 별도
증거로 기록한다.

```text
nimble test
nimble verify
nimble check
nimble docsCheck
git diff --check
```

이 문서의 예제는 core contract와 adapter ownership을 설명하기 위한 것이다.
provider SDK나 외부 ORM의 구체적인 설정은 지원 버전과 application deployment
문서에서 별도로 고정한다.

로컬 storage/static/cache의 최소 실행은
[`examples/local_storage.nim`](../examples/local_storage.nim)과
`nimble docsExamples`에 포함되어 있다. 이 예제의 `ttlSeconds = 60`은 local cache
계약만 보여 주며 provider의 eviction·cross-process 일관성은 보장하지 않는다.

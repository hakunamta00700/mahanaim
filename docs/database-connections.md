# 데이터베이스 연결과 트랜잭션

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** developers choosing a database adapter, pool, and unit of work.
**Verified with:** `nimble test`

Create a bounded `DatabaseConnectionPool` from an application-owned adapter
factory and configure it before startup. `Application.dispatch` borrows a
connection for each request and releases it on success, error, timeout, and
cancellation. Pool exhaustion is visible, not an unbounded connection burst.

For transactional work use `withDatabaseSession(pool, operation)` or a
`newDatabaseSession`. It begins a transaction, commits on success, rolls back on
failure, and releases the exact borrowed adapter. `setIsolationLevel` requires
an active transaction; capability and SQL semantics remain adapter specific.

The pool owns admission and lifetime; adapters own queries, transactions,
savepoints, and backend capabilities. Pass a current request/session adapter to
repositories instead of opening hidden global connections. Keep transactions
short and avoid network calls inside them.

For the repository boundary and an external ORM bridge that keeps session and
unit-of-work ownership in the application, read
[Storage/ORM integration](storage-and-orm-integration.md).

## 민감 데이터·관계·isolation 검증

모델의 `sensitive` field는 일반 serializer response에서 제외하고, relation은
endpoint가 eager/lazy loading을 명시적으로 선택한다. 이 두 규칙과 transaction
rollback은 `nimble test`의 metadata serializer·relation repository·database session
contract로 검증한다. `isolationSerializable`처럼 isolation level을 요청할 때는
현재 adapter capability를 먼저 확인한다. 지원하지 않는 isolation은 조용히
fallback하지 않으며, provider 문서와 live contract에서 별도로 검증한다.

관련 문서: [모델과 메타데이터](models-and-metadata.md), [직렬화](serialization.md),
[migration](migrations.md), [데이터베이스 연결](database-connections.md).

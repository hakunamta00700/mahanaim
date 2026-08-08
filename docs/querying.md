# Querying and repositories

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** developers writing portable, parameter-bound database queries.
**Verified with:** `nimble test`

`newQuerySet(table)` starts with no implicit `SELECT *`; select a projection
before compilation. Queries are values, so filters and values remain distinct
from SQL text and are bound by the selected adapter.

```nim
let query = newQuerySet("products")
  .selectFields(["id", "name", "price"])
  .orderByField("name")
  .paginate(Pagination(limit: 20, offset: 0))
let compiled = query.compile(dialectSqlite)
```

The builder supports projection, bound filters, deterministic sort, grouping,
aggregates, arithmetic annotations, pagination, and `lockRows`. It rejects empty
projections, invalid identifiers, negative pagination, and adapter-unsupported
lock modes. Pagination is bounded limit/offset; cursor policy is application-owned
and must include a stable sort key.

`DatabaseRepository` maps metadata-owned names to storage and provides CRUD plus
relation loading helpers. Eager/lazy relation choice remains explicit; measure
query count and memory rather than assuming a relation is loaded.

When a project uses another ORM, keep its entity/session lifecycle in an
application-owned bridge rather than putting it in a route or the framework
core. The ownership and transaction boundary is documented in
[Storage/ORM integration](storage-and-orm-integration.md).

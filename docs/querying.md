# Querying and repositories

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

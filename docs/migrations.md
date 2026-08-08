# Migrations

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** maintainers evolving SQLite or PostgreSQL schemas.
**Verified with:** `nimble test`, `mahanaim db status|up|rollback|seed`

Register migrations in application composition, then use the CLI to inspect and
apply them. Typical local flow is `mahanaim db status`, `mahanaim db up`, and
`mahanaim db seed`; use `mahanaim db rollback` only for a known reversible
migration and verified backup.

Each migration is ordered and checked by its registry. Keep an explicit forward
operation and tested rollback. Treat destructive changes as a multi-release
procedure: add compatible schema, backfill, deploy read/write code, verify, then
remove old data later.

SQLite is the stable local target. PostgreSQL support is experimental and requires
the optional adapter/live contract; verify dialect SQL, transactions, locking, and
credentials separately. A passing SQLite migration is not production proof.

For a complete, executable SQLite path from metadata through CRUD and rollback,
follow the [SQLite CRUD and migration tutorial](sqlite-crud-migration-tutorial.md).
For PostgreSQL configuration, optional live gates, and provider limits, see
[PostgreSQL configuration and limits](postgresql.md).

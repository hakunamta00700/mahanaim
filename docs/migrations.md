# Migrations

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

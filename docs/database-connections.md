# Database connections and transactions

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

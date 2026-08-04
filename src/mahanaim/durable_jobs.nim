## Durable job payload storage boundary.
##
## A Nim closure is not a portable durable payload. This module therefore stores
## a named job kind and opaque payload; an application-owned handler registry
## decides how to execute it. SQLite is the reference adapter, while external
## queues can implement the same state transition contract.

import std/[asyncdispatch, locks, options, strutils, tables]
import pkg/db_connector/db_sqlite
import ./jobs

type
  DurableJobStatus* = enum
    djsPending
    djsProcessing
    djsCompleted

  DurableJobRecord* = object
    id*: string
    kind*: string
    payload*: string
    status*: DurableJobStatus
    attempts*: int

  DurableJobStore* = ref object of RootObj

  DurableJobHandler* = proc(payload: string) {.gcsafe.}

  DurableJobRegistry* = ref object
    ## Kind-to-handler registration remains application-owned. The durable
    ## store never executes arbitrary payload text or discovers code by name.
    handlers: Table[string, DurableJobHandler]

  DurableJobRunResult* = object
    processed*: bool
    succeeded*: bool
    id*: string
    attempts*: int
    error*: string

  SqliteDurableJobStore* = ref object of DurableJobStore
    path*: string
    connection: DbConn
    lock: Lock

proc newDurableJobRegistry*(): DurableJobRegistry =
  new(result)
  result.handlers = initTable[string, DurableJobHandler]()

proc registerHandler*(registry: DurableJobRegistry, kind: string,
                      handler: DurableJobHandler) =
  ## Duplicate kinds are rejected so plugin load order cannot silently replace
  ## a handler for already persisted jobs.
  if registry.isNil or kind.strip().len == 0 or handler.isNil:
    raise newException(ValueError, "Durable job kind and handler are required")
  if registry.handlers.hasKey(kind):
    raise newException(ValueError, "Duplicate durable job handler: " & kind)
  registry.handlers[kind] = handler

method enqueue*(store: DurableJobStore, id, kind, payload: string) {.base, gcsafe.} =
  discard store
  discard id
  discard kind
  discard payload
  raise newException(ValueError, "Durable job store does not implement enqueue")

method claimNext*(store: DurableJobStore): Option[DurableJobRecord] {.base, gcsafe.} =
  discard store
  raise newException(ValueError, "Durable job store does not implement claimNext")

method complete*(store: DurableJobStore, id: string) {.base, gcsafe.} =
  discard store
  discard id
  raise newException(ValueError, "Durable job store does not implement complete")

method release*(store: DurableJobStore, id: string) {.base, gcsafe.} =
  discard store
  discard id
  raise newException(ValueError, "Durable job store does not implement release")

method recoverProcessing*(store: DurableJobStore) {.base, gcsafe.} =
  discard store
  raise newException(ValueError,
    "Durable job store does not implement recoverProcessing")

method close*(store: DurableJobStore) {.base, gcsafe.} =
  ## Application shutdown calls this hook without knowing the concrete
  ## persistence backend. External queue adapters may override it to release
  ## connections; the base implementation is intentionally a no-op.
  discard store

proc runNext*(registry: DurableJobRegistry, store: DurableJobStore,
              queue: BackgroundJobQueue): Future[DurableJobRunResult] {.async.} =
  ## Claim one record, execute its named handler through the existing bounded
  ## executor, and advance durable state only after the handler succeeds.
  if registry.isNil or store.isNil or queue.isNil:
    raise newException(ValueError,
      "Durable job registry, store, and queue are required")
  let claimed = store.claimNext()
  if claimed.isNone:
    return DurableJobRunResult(processed: false)
  let record = claimed.get()
  result.processed = true
  result.id = record.id
  result.attempts = record.attempts
  if not registry.handlers.hasKey(record.kind):
    store.release(record.id)
    result.error = "No durable job handler registered: " & record.kind
    return
  let handler = registry.handlers[record.kind]
  let payload = record.payload
  let execution = await queue.enqueue(proc() {.gcsafe.} = handler(payload))
  if execution.succeeded:
    store.complete(record.id)
    result.succeeded = true
  else:
    store.release(record.id)
    result.error = execution.error

const durableJobsTable = "__mahanaim_durable_jobs"

proc newSqliteDurableJobStore*(path = ":memory:"): SqliteDurableJobStore =
  if path.strip().len == 0:
    raise newException(ValueError, "Durable job SQLite path is required")
  new(result)
  result.path = path
  result.connection = db_sqlite.open(path, "", "", "")
  initLock(result.lock)
  result.connection.exec(SqlQuery(
    "CREATE TABLE IF NOT EXISTS \"" & durableJobsTable & "\" (" &
    "\"id\" TEXT PRIMARY KEY NOT NULL, " &
    "\"kind\" TEXT NOT NULL, \"payload\" TEXT NOT NULL, " &
    "\"status\" TEXT NOT NULL, \"attempts\" INTEGER NOT NULL DEFAULT 0)"))

method close*(store: SqliteDurableJobStore) {.gcsafe.} =
  if store.isNil:
    return
  acquire(store.lock)
  try:
    if not store.connection.isNil:
      store.connection.close()
      store.connection = nil
  finally:
    release(store.lock)

method enqueue*(store: SqliteDurableJobStore, id, kind, payload: string)
    {.gcsafe.} =
  if store.isNil or id.strip().len == 0 or kind.strip().len == 0:
    raise newException(ValueError, "Durable job id and kind are required")
  acquire(store.lock)
  try:
    if store.connection.isNil:
      raise newException(ValueError, "Durable job store is closed")
    store.connection.exec(SqlQuery(
      "INSERT INTO \"" & durableJobsTable &
      "\" (\"id\", \"kind\", \"payload\", \"status\") " &
      "VALUES (?, ?, ?, 'pending')"), id, kind, payload)
  finally:
    release(store.lock)

method claimNext*(store: SqliteDurableJobStore): Option[DurableJobRecord]
    {.gcsafe.} =
  if store.isNil:
    raise newException(ValueError, "Durable job store is required")
  acquire(store.lock)
  try:
    if store.connection.isNil:
      raise newException(ValueError, "Durable job store is closed")
    ## BEGIN IMMEDIATE serializes claimers across SQLite connections. We read
    ## and update within the same transaction so one pending row is owned once.
    store.connection.exec(SqlQuery("BEGIN IMMEDIATE"))
    var rows: seq[Row] = @[]
    for row in store.connection.fastRows(SqlQuery(
        "SELECT \"id\", \"kind\", \"payload\", \"attempts\" FROM \"" &
        durableJobsTable & "\" WHERE \"status\" = 'pending' " &
        "ORDER BY rowid LIMIT 1")):
      rows.add(row)
    if rows.len == 0:
      store.connection.exec(SqlQuery("COMMIT"))
      return none(DurableJobRecord)
    let row = rows[0]
    let id = row[0]
    let attempts = parseInt(row[3]) + 1
    store.connection.exec(SqlQuery(
      "UPDATE \"" & durableJobsTable &
      "\" SET \"status\" = 'processing', \"attempts\" = ? " &
      "WHERE \"id\" = ?"), $attempts, id)
    store.connection.exec(SqlQuery("COMMIT"))
    some(DurableJobRecord(id: id, kind: row[1], payload: row[2],
      status: djsProcessing, attempts: attempts))
  except CatchableError:
    try: store.connection.exec(SqlQuery("ROLLBACK"))
    except CatchableError: discard
    raise
  finally:
    release(store.lock)

method complete*(store: SqliteDurableJobStore, id: string) {.gcsafe.} =
  if store.isNil or id.strip().len == 0:
    raise newException(ValueError, "Durable job store and id are required")
  acquire(store.lock)
  try:
    store.connection.exec(SqlQuery(
      "UPDATE \"" & durableJobsTable & "\" SET \"status\" = 'completed' " &
      "WHERE \"id\" = ? AND \"status\" = 'processing'"), id)
  finally:
    release(store.lock)

method release*(store: SqliteDurableJobStore, id: string) {.gcsafe.} =
  if store.isNil or id.strip().len == 0:
    raise newException(ValueError, "Durable job store and id are required")
  acquire(store.lock)
  try:
    store.connection.exec(SqlQuery(
      "UPDATE \"" & durableJobsTable & "\" SET \"status\" = 'pending' " &
      "WHERE \"id\" = ? AND \"status\" = 'processing'"), id)
  finally:
    release(store.lock)

method recoverProcessing*(store: SqliteDurableJobStore) {.gcsafe.} =
  if store.isNil:
    raise newException(ValueError, "Durable job store is required")
  acquire(store.lock)
  try:
    store.connection.exec(SqlQuery(
      "UPDATE \"" & durableJobsTable & "\" SET \"status\" = 'pending' " &
      "WHERE \"status\" = 'processing'"))
  finally:
    release(store.lock)

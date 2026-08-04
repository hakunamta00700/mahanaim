## Backend-neutral database connection pool.
##
## The pool owns connection admission and lifetime only. Query execution,
## transactions, savepoints, and backend capability decisions stay on the
## DatabaseAdapter so borrowing a connection cannot change SQL semantics.

import std/[locks, tables]
import ./database

type
  DatabaseAdapterFactory* = proc(): DatabaseAdapter {.gcsafe.}
  DatabaseAdapterCloser* = proc(adapter: DatabaseAdapter) {.gcsafe.}

  DatabaseConnectionPool* = ref object
    ## A pool is deliberately independent from a concrete driver. The factory
    ## may create SQLite, PostgreSQL, or a test adapter under the same contract.
    factory: DatabaseAdapterFactory
    closer: DatabaseAdapterCloser
    maxConnections*: int
    available: seq[DatabaseAdapter]
    members: Table[pointer, bool]
    closed: bool
    lock: Lock

proc newDatabaseConnectionPool*(factory: DatabaseAdapterFactory,
                                maxConnections = 4,
                                closer: DatabaseAdapterCloser = nil):
    DatabaseConnectionPool =
  ## A positive bound makes overload visible instead of creating unbounded
  ## native connections under request bursts.
  if factory.isNil:
    raise newException(ValueError, "Database pool requires a connection factory")
  if maxConnections < 1:
    raise newException(ValueError, "Database pool size must be positive")
  new(result)
  result.factory = factory
  result.closer = closer
  result.maxConnections = maxConnections
  result.available = @[]
  result.members = initTable[pointer, bool]()
  initLock(result.lock)

proc closeAdapter(pool: DatabaseConnectionPool,
                  adapter: DatabaseAdapter) {.gcsafe.} =
  if pool.closer != nil and adapter != nil:
    pool.closer(adapter)

proc acquire*(pool: DatabaseConnectionPool): DatabaseAdapter {.gcsafe.} =
  ## Borrow an existing connection or create one while capacity remains.
  ## Factory execution is kept inside the admission lock to prevent two
  ## callers from exceeding the native connection bound.
  if pool.isNil:
    raise newException(ValueError, "Database pool is required")
  acquire(pool.lock)
  try:
    if pool.closed:
      raise newException(ValueError, "Database pool is closed")
    if pool.available.len > 0:
      result = pool.available.pop()
      pool.members[cast[pointer](result)] = true
      return
    if pool.members.len >= pool.maxConnections:
      raise newException(ResourceExhaustedError,
        "Database connection pool capacity exhausted")
    result = pool.factory()
    if result.isNil:
      raise newException(CatchableError,
        "Database connection factory returned nil")
    let key = cast[pointer](result)
    if pool.members.hasKey(key):
      raise newException(CatchableError,
        "Database connection factory returned a duplicate adapter")
    pool.members[key] = true
  finally:
    release(pool.lock)

proc release*(pool: DatabaseConnectionPool,
              adapter: DatabaseAdapter) {.gcsafe.} =
  ## Return a connection exactly once. Connections returned after pool close
  ## are closed immediately so shutdown does not leave native handles alive.
  if pool.isNil or adapter.isNil:
    raise newException(ValueError, "Database pool and adapter are required")
  var closeNow = false
  acquire(pool.lock)
  try:
    let key = cast[pointer](adapter)
    if not pool.members.hasKey(key) or not pool.members[key]:
      raise newException(ValueError, "Database adapter is not currently borrowed")
    if pool.closed:
      pool.members.del(key)
      closeNow = true
    else:
      pool.members[key] = false
      pool.available.add(adapter)
  finally:
    release(pool.lock)
  if closeNow:
    pool.closeAdapter(adapter)

proc withConnection*(pool: DatabaseConnectionPool,
                     operation: proc(adapter: DatabaseAdapter)) =
  ## Centralize release in a finally block so application errors never leak a
  ## borrowed connection back into the process-wide pool.
  let adapter = pool.acquire()
  try:
    operation(adapter)
  finally:
    pool.release(adapter)

proc close*(pool: DatabaseConnectionPool) =
  ## Close idle connections now; active borrowers are closed on their next
  ## release. This makes shutdown deterministic without interrupting a query.
  if pool.isNil:
    return
  var idle: seq[DatabaseAdapter] = @[]
  acquire(pool.lock)
  try:
    if pool.closed:
      return
    pool.closed = true
    idle = pool.available
    pool.available = @[]
    for adapter in idle:
      pool.members.del(cast[pointer](adapter))
  finally:
    release(pool.lock)
  for adapter in idle:
    pool.closeAdapter(adapter)

proc idleCount*(pool: DatabaseConnectionPool): int {.gcsafe.} =
  if pool.isNil:
    return 0
  acquire(pool.lock)
  try:
    pool.available.len
  finally:
    release(pool.lock)

proc activeCount*(pool: DatabaseConnectionPool): int {.gcsafe.} =
  if pool.isNil:
    return 0
  acquire(pool.lock)
  try:
    pool.members.len - pool.available.len
  finally:
    release(pool.lock)

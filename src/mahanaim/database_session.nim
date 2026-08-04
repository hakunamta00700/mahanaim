## Request/task-scoped database unit-of-work.
##
## A pool controls which connection is borrowed; this session controls the
## transaction boundary on that exact connection. Keeping the responsibilities
## separate prevents a commit from accidentally occurring on another adapter.

import ./database
import ./database_pool

type
  DatabaseSession* = ref object
    pool: DatabaseConnectionPool
    adapter*: DatabaseAdapter
    transactionActive: bool
    closed: bool

proc newDatabaseSession*(pool: DatabaseConnectionPool,
                         transactional = true): DatabaseSession =
  ## Borrow once and optionally begin immediately. Non-transactional sessions
  ## are useful for read-only handlers while retaining the same release rule.
  if pool.isNil:
    raise newException(ValueError, "Database session requires a pool")
  new(result)
  result.pool = pool
  result.adapter = pool.acquire()
  result.transactionActive = false
  result.closed = false
  if transactional:
    try:
      result.adapter.begin()
      result.transactionActive = true
    except CatchableError:
      pool.release(result.adapter)
      result.adapter = nil
      raise

proc commit*(session: DatabaseSession) =
  ## Commit exactly once; a closed or already completed session is rejected.
  if session.isNil or session.closed or session.adapter.isNil:
    raise newException(ValueError, "Database session is closed")
  if not session.transactionActive:
    raise newException(ValueError, "Database session has no active transaction")
  session.adapter.commit()
  session.transactionActive = false

proc rollback*(session: DatabaseSession) =
  ## Rollback is idempotent for cleanup paths but still rejects a closed session.
  if session.isNil or session.closed or session.adapter.isNil:
    raise newException(ValueError, "Database session is closed")
  if session.transactionActive:
    session.adapter.rollback()
    session.transactionActive = false

proc setIsolationLevel*(session: DatabaseSession,
                        level: TransactionIsolationLevel) =
  ## Isolation belongs to the current unit-of-work. Requiring an active
  ## transaction prevents a setting from being applied to a later borrowed
  ## connection by accident, while adapters retain backend-specific support.
  if session.isNil or session.closed or session.adapter.isNil:
    raise newException(ValueError, "Database session is closed")
  if not session.transactionActive:
    raise newException(ValueError,
      "Database session has no active transaction")
  session.adapter.setIsolationLevel(level)

proc close*(session: DatabaseSession) =
  ## Unfinished work is rolled back before returning the connection to the pool.
  if session.isNil or session.closed:
    return
  try:
    if session.transactionActive:
      session.adapter.rollback()
      session.transactionActive = false
  finally:
    session.pool.release(session.adapter)
    session.adapter = nil
    session.closed = true

proc withDatabaseSession*(pool: DatabaseConnectionPool,
                          operation: proc(session: DatabaseSession)) =
  ## The canonical all-or-rollback helper for request/task work.
  let session = newDatabaseSession(pool)
  try:
    operation(session)
    session.commit()
  except CatchableError:
    session.rollback()
    raise
  finally:
    session.close()

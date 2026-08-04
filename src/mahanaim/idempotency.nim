## Idempotency claim boundary for background work.
##
## The queue only needs an atomic claim/release contract. Durable stores can
## implement it with a database unique key or an external queue; the in-memory
## adapter is intentionally a deterministic reference for local development.

import std/[locks, os, strutils, tables]

type
  IdempotencyStore* = ref object of RootObj

  InMemoryIdempotencyStore* = ref object of IdempotencyStore
    keys: Table[string, bool]
    lock: Lock

  FileIdempotencyStore* = ref object of IdempotencyStore
    ## The journal survives process restart, while the lock only coordinates
    ## writers within this process. Multi-process deployments need a database
    ## or external queue adapter with an atomic unique constraint.
    path*: string
    keys: Table[string, bool]
    lock: Lock

method claim*(store: IdempotencyStore, key: string): bool {.base, gcsafe.} =
  discard store
  discard key
  raise newException(ValueError, "Idempotency store does not implement claim")

method release*(store: IdempotencyStore, key: string) {.base, gcsafe.} =
  discard store
  discard key
  raise newException(ValueError, "Idempotency store does not implement release")

proc newInMemoryIdempotencyStore*(): InMemoryIdempotencyStore =
  ## Locking makes claim atomic when several executor workers race on one key.
  new(result)
  result.keys = initTable[string, bool]()
  initLock(result.lock)

method claim*(store: InMemoryIdempotencyStore, key: string): bool {.gcsafe.} =
  if store.isNil or key.strip().len == 0:
    raise newException(ValueError, "Idempotency store and key are required")
  acquire(store.lock)
  try:
    if store.keys.hasKey(key):
      return false
    store.keys[key] = true
    true
  finally:
    release(store.lock)

method release*(store: InMemoryIdempotencyStore, key: string) {.gcsafe.} =
  if store.isNil or key.strip().len == 0:
    raise newException(ValueError, "Idempotency store and key are required")
  acquire(store.lock)
  try:
    store.keys.del(key)
  finally:
    release(store.lock)

proc applyJournalLine(keys: var Table[string, bool], line: string) =
  ## Ignore an incomplete final line so a process interrupted during append
  ## cannot turn a valid journal into an unreadable store.
  if line.len < 3 or line[1] != '\t':
    return
  let key = line[2 .. ^1]
  if key.len == 0:
    return
  case line[0]
  of 'C': keys[key] = true
  of 'R': keys.del(key)
  else: discard

proc newFileIdempotencyStore*(path: string): FileIdempotencyStore =
  ## Append-only records avoid rewriting the full key set during release. A
  ## compaction command can be added later without changing claim semantics.
  if path.strip().len == 0:
    raise newException(ValueError, "Idempotency journal path is required")
  new(result)
  result.path = path
  result.keys = initTable[string, bool]()
  initLock(result.lock)
  if fileExists(path):
    for line in readFile(path).splitLines():
      result.keys.applyJournalLine(line)

proc appendJournal(store: FileIdempotencyStore, operation: char, key: string) =
  if key.contains({'\r', '\n', '\t'}):
    raise newException(ValueError, "Idempotency key contains journal control characters")
  var journal = open(store.path, fmAppend)
  try:
    journal.write($operation & "\t" & key & "\n")
  finally:
    journal.close()

method claim*(store: FileIdempotencyStore, key: string): bool {.gcsafe.} =
  if store.isNil or key.strip().len == 0:
    raise newException(ValueError, "Idempotency store and key are required")
  acquire(store.lock)
  try:
    if store.keys.hasKey(key):
      return false
    store.appendJournal('C', key)
    store.keys[key] = true
    true
  finally:
    release(store.lock)

method release*(store: FileIdempotencyStore, key: string) {.gcsafe.} =
  if store.isNil or key.strip().len == 0:
    raise newException(ValueError, "Idempotency store and key are required")
  acquire(store.lock)
  try:
    if store.keys.hasKey(key):
      store.appendJournal('R', key)
      store.keys.del(key)
  finally:
    release(store.lock)

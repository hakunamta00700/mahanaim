## Idempotency claim boundary for background work.
##
## The queue only needs an atomic claim/release contract. Durable stores can
## implement it with a database unique key or an external queue; the in-memory
## adapter is intentionally a deterministic reference for local development.

import std/[locks, strutils, tables]

type
  IdempotencyStore* = ref object of RootObj

  InMemoryIdempotencyStore* = ref object of IdempotencyStore
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

## Backend-neutral one-time messages for server-rendered flows.
##
## Flash storage is deliberately separate from sessions and templates: a
## session identifier is the only ownership key, while applications can
## replace the in-memory adapter with a durable or distributed implementation.

import std/[locks, strutils, tables]

type
  FlashCategory* = enum
    ## Categories are presentation hints, not authorization or control data.
    flashInfo
    flashSuccess
    flashWarning
    flashError

  FlashMessage* = object
    category*: FlashCategory
    message*: string

  FlashStore* = ref object of RootObj
    ## Adapter boundary for one-time messages associated with a session key.

  InMemoryFlashStore* = ref object of FlashStore
    messages: Table[string, seq[FlashMessage]]
    maxMessagesPerSession: int
    lock: Lock

method push*(store: FlashStore, sessionId: string,
             message: FlashMessage) {.base, gcsafe.} =
  ## Concrete stores must make append atomic and preserve consume-once
  ## semantics. The base method fails loudly instead of losing a message.
  discard store
  discard sessionId
  discard message
  raise newException(ValueError, "Flash store does not implement push")

method consume*(store: FlashStore, sessionId: string): seq[FlashMessage]
    {.base, gcsafe.} =
  ## Consumption removes the queue in one operation so a retry cannot render
  ## the same success or error message twice.
  discard store
  discard sessionId
  raise newException(ValueError, "Flash store does not implement consume")

method clear*(store: FlashStore, sessionId: string) {.base, gcsafe.} =
  ## Clear is useful when a session is invalidated or explicitly logged out.
  discard store
  discard sessionId
  raise newException(ValueError, "Flash store does not implement clear")

proc newInMemoryFlashStore*(maxMessagesPerSession = 8): InMemoryFlashStore =
  ## The reference adapter is bounded per session to prevent an abandoned
  ## browser session from growing process memory without limit.
  if maxMessagesPerSession < 1:
    raise newException(ValueError, "Flash store capacity must be positive")
  new(result)
  result.messages = initTable[string, seq[FlashMessage]]()
  result.maxMessagesPerSession = maxMessagesPerSession
  initLock(result.lock)

method push*(store: InMemoryFlashStore, sessionId: string,
             message: FlashMessage) {.gcsafe.} =
  if store.isNil or sessionId.strip().len == 0:
    raise newException(ValueError, "Flash session identifier is required")
  if message.message.strip().len == 0:
    raise newException(ValueError, "Flash message must not be empty")
  acquire(store.lock)
  defer: release(store.lock)
  var queue = store.messages.getOrDefault(sessionId, @[])
  queue.add(message)
  if queue.len > store.maxMessagesPerSession:
    let firstKept = queue.len - store.maxMessagesPerSession
    queue = queue[firstKept .. ^1]
  store.messages[sessionId] = queue

method consume*(store: InMemoryFlashStore,
                sessionId: string): seq[FlashMessage] {.gcsafe.} =
  if store.isNil or sessionId.strip().len == 0:
    return @[]
  acquire(store.lock)
  defer: release(store.lock)
  if not store.messages.hasKey(sessionId):
    return @[]
  result = store.messages[sessionId]
  store.messages.del(sessionId)

method clear*(store: InMemoryFlashStore, sessionId: string) {.gcsafe.} =
  if store.isNil or sessionId.strip().len == 0:
    return
  acquire(store.lock)
  defer: release(store.lock)
  store.messages.del(sessionId)

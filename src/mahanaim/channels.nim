## Framework-neutral channel/group broadcast contracts.
##
## A channel layer coordinates application messages, while a WebSocket
## adapter remains responsible for turning those messages into wire frames.
## The initial in-memory backend is deterministic for tests and local use;
## distributed backends can implement the same virtual contract later.

import std/[asyncdispatch, strutils, tables]
import ./core

type
  ChannelSubscriber* = proc(message: WebSocketMessage): Future[void] {.gcsafe.}

  ChannelSubscription* = ref object
    ## A subscription is a revocable capability for one group membership.
    id*: int
    group*: string
    active*: bool
    subscriber: ChannelSubscriber

  ChannelLayer* = ref object of RootObj
    ## Backends implement this small contract without exposing storage or
    ## broker-specific types to application code.

  InMemoryChannelLayer* = ref object of ChannelLayer
    nextId: int
    subscriptions: Table[string, seq[ChannelSubscription]]

method subscribe*(layer: ChannelLayer, group: string,
                  subscriber: ChannelSubscriber): ChannelSubscription {.base.} =
  raise newException(ValueError, "channel layer does not support subscribe")

method unsubscribe*(layer: ChannelLayer,
                    subscription: ChannelSubscription) {.base.} =
  raise newException(ValueError, "channel layer does not support unsubscribe")

method publish*(layer: ChannelLayer, group: string,
                message: WebSocketMessage): Future[int] {.base.} =
  raise newException(ValueError, "channel layer does not support publish")

proc validateGroup(group: string) =
  if group.strip().len == 0:
    raise newException(ValueError, "channel group must not be empty")

proc validateSubscriber(subscriber: ChannelSubscriber) =
  if subscriber.isNil:
    raise newException(ValueError, "channel subscriber must not be nil")

method subscribe*(layer: InMemoryChannelLayer, group: string,
                  subscriber: ChannelSubscriber): ChannelSubscription =
  validateGroup(group)
  validateSubscriber(subscriber)
  inc layer.nextId
  result = ChannelSubscription(id: layer.nextId, group: group.strip(),
                               active: true, subscriber: subscriber)
  var entries = layer.subscriptions.getOrDefault(result.group, @[])
  entries.add(result)
  layer.subscriptions[result.group] = entries

method unsubscribe*(layer: InMemoryChannelLayer,
                    subscription: ChannelSubscription) =
  ## Unsubscribe is idempotent so connection cleanup can safely run on every
  ## exit path, including handler errors and client disconnects.
  if subscription.isNil or not subscription.active:
    return
  subscription.active = false
  var entries = layer.subscriptions.getOrDefault(subscription.group, @[])
  var retained: seq[ChannelSubscription] = @[]
  for entry in entries:
    if entry != subscription and entry.active:
      retained.add(entry)
  if retained.len == 0:
    layer.subscriptions.del(subscription.group)
  else:
    layer.subscriptions[subscription.group] = retained

proc publishInMemory(layer: InMemoryChannelLayer, group: string,
                     message: WebSocketMessage): Future[int] {.async.} =
  validateGroup(group)
  ## Snapshot membership before awaiting callbacks. A callback may unsubscribe
  ## itself or another session without invalidating this publication.
  let entries = layer.subscriptions.getOrDefault(group.strip(), @[])
  for entry in entries:
    if entry.active:
      try:
        await entry.subscriber(message)
        inc result
      except CatchableError:
        ## One disconnected client must not prevent delivery to other clients.
        discard

method publish*(layer: InMemoryChannelLayer, group: string,
                message: WebSocketMessage): Future[int] =
  publishInMemory(layer, group, message)

proc newInMemoryChannelLayer*(): ChannelLayer =
  ## Use the abstract return type so changing to a distributed backend does
  ## not force application code to depend on a concrete channel store.
  new(result)
  let memory = InMemoryChannelLayer(nextId: 0,
                                    subscriptions: initTable[string, seq[ChannelSubscription]]())
  result = memory

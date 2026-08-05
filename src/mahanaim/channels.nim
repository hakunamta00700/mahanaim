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

  ChannelSubscribeProc* = proc(group: string,
                                subscriber: ChannelSubscriber): ChannelSubscription {.gcsafe.}
  ChannelUnsubscribeProc* = proc(subscription: ChannelSubscription) {.gcsafe.}
  ChannelPublishProc* = proc(group: string, message: WebSocketMessage): Future[int] {.gcsafe.}

  CallbackChannelLayer* = ref object of ChannelLayer
    ## Adapter bridge for a broker-owned implementation. The callbacks may
    ## use Redis/Valkey pub/sub, a queue, or a process-local test double while
    ## the application continues to depend only on ChannelLayer.
    subscribeProc*: ChannelSubscribeProc
    unsubscribeProc*: ChannelUnsubscribeProc
    publishProc*: ChannelPublishProc

  InMemoryChannelLayer* = ref object of ChannelLayer
    nextId: int
    subscriptions: Table[string, seq[ChannelSubscription]]

  WebSocketChannelBinding* = ref object
    ## Owns the lifetime bridge between one WebSocket session and one group
    ## subscription. The channel layer still knows nothing about sockets.
    layer*: ChannelLayer
    subscription*: ChannelSubscription
    session*: WebSocketSession
    originalClose: WebSocketCloseProc
    closed: bool

method subscribe*(layer: ChannelLayer, group: string,
                  subscriber: ChannelSubscriber): ChannelSubscription {.base, gcsafe.} =
  raise newException(ValueError, "channel layer does not support subscribe")

method unsubscribe*(layer: ChannelLayer,
                    subscription: ChannelSubscription) {.base, gcsafe.} =
  raise newException(ValueError, "channel layer does not support unsubscribe")

method publish*(layer: ChannelLayer, group: string,
                message: WebSocketMessage): Future[int] {.base, gcsafe.} =
  raise newException(ValueError, "channel layer does not support publish")

method subscribe*(layer: CallbackChannelLayer, group: string,
                  subscriber: ChannelSubscriber): ChannelSubscription {.gcsafe.} =
  if layer.isNil or layer.subscribeProc.isNil:
    raise newException(ValueError, "channel adapter has no subscribe callback")
  layer.subscribeProc(group, subscriber)

method unsubscribe*(layer: CallbackChannelLayer,
                    subscription: ChannelSubscription) {.gcsafe.} =
  if layer.isNil or layer.unsubscribeProc.isNil:
    raise newException(ValueError, "channel adapter has no unsubscribe callback")
  layer.unsubscribeProc(subscription)

method publish*(layer: CallbackChannelLayer, group: string,
                message: WebSocketMessage): Future[int] {.gcsafe.} =
  if layer.isNil or layer.publishProc.isNil:
    raise newException(ValueError, "channel adapter has no publish callback")
  layer.publishProc(group, message)

proc validateGroup(group: string) =
  if group.strip().len == 0:
    raise newException(ValueError, "channel group must not be empty")

proc validateSubscriber(subscriber: ChannelSubscriber) =
  if subscriber.isNil:
    raise newException(ValueError, "channel subscriber must not be nil")

proc newCallbackChannelLayer*(subscribeProc: ChannelSubscribeProc,
                              unsubscribeProc: ChannelUnsubscribeProc,
                              publishProc: ChannelPublishProc): ChannelLayer =
  ## Require all three operations up front. A partially configured adapter
  ## would otherwise fail only after a live connection has joined a group.
  if subscribeProc.isNil or unsubscribeProc.isNil or publishProc.isNil:
    raise newException(ValueError, "channel adapter callbacks are required")
  new(result)
  result = CallbackChannelLayer(subscribeProc: subscribeProc,
                                unsubscribeProc: unsubscribeProc,
                                publishProc: publishProc)

method subscribe*(layer: InMemoryChannelLayer, group: string,
                  subscriber: ChannelSubscriber): ChannelSubscription {.gcsafe.} =
  validateGroup(group)
  validateSubscriber(subscriber)
  inc layer.nextId
  result = ChannelSubscription(id: layer.nextId, group: group.strip(),
                               active: true, subscriber: subscriber)
  var entries = layer.subscriptions.getOrDefault(result.group, @[])
  entries.add(result)
  layer.subscriptions[result.group] = entries

method unsubscribe*(layer: InMemoryChannelLayer,
                    subscription: ChannelSubscription) {.gcsafe.} =
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
                     message: WebSocketMessage): Future[int] {.async, gcsafe.} =
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
                message: WebSocketMessage): Future[int] {.gcsafe.} =
  publishInMemory(layer, group, message)

proc newInMemoryChannelLayer*(): ChannelLayer =
  ## Use the abstract return type so changing to a distributed backend does
  ## not force application code to depend on a concrete channel store.
  new(result)
  let memory = InMemoryChannelLayer(nextId: 0,
                                    subscriptions: initTable[string, seq[ChannelSubscription]]())
  result = memory

proc unbind*(binding: WebSocketChannelBinding, code = 1000,
             reason = ""): Future[void] {.async, gcsafe.} =
  ## Cleanup is deliberately idempotent because either the handler or the
  ## transport can observe a disconnect first. Restore the adapter callback
  ## before invoking it so a callback that closes again cannot recurse into
  ## this binding.
  if binding.isNil or binding.closed:
    return
  binding.closed = true
  if not binding.layer.isNil:
    binding.layer.unsubscribe(binding.subscription)
  let originalClose = binding.originalClose
  if not binding.session.isNil:
    binding.session.closeSession = originalClose
  if not originalClose.isNil:
    await originalClose(code, reason)

proc bindWebSocketSession*(layer: ChannelLayer, group: string,
                           session: WebSocketSession): WebSocketChannelBinding =
  ## Register a session as a channel subscriber and wrap only its close
  ## callback. Send/receive framing remains fully owned by the adapter.
  if layer.isNil:
    raise newException(ValueError, "channel layer must not be nil")
  if session.isNil:
    raise newException(ValueError, "WebSocket session must not be nil")
  if session.closeSession.isNil:
    raise newException(ValueError, "WebSocket session must have a close callback")
  new(result)
  result.layer = layer
  result.session = session
  result.originalClose = session.closeSession
  let binding = result
  let subscriber: ChannelSubscriber = proc(message: WebSocketMessage): Future[void] {.async, gcsafe.} =
    await binding.session.send(message)
  result.subscription = layer.subscribe(group, subscriber)
  session.closeSession = proc(code: int, reason: string): Future[void] {.async, gcsafe.} =
    await binding.unbind(code, reason)

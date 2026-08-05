## Redis-backed distributed ChannelLayer.
##
## This module is deliberately separate from both the framework-neutral channel
## contract and the low-level Redis pub/sub socket. It owns only the translation
## between WebSocketMessage values and Redis payloads, remote subscription
## acknowledgement, and non-blocking publish lifecycle. Applications can keep
## depending on ChannelLayer while choosing Redis only in composition code.

import std/[asyncdispatch, asyncnet, strutils, tables]
import ./core
import ./channels
import ./redis_channels
import ./redis_resp

const redisChannelWirePrefix = "MAHANAIM-CHANNEL-1:"

proc encodeRedisChannelMessage*(message: WebSocketMessage): string =
  ## A length-delimited envelope preserves arbitrary binary payloads and avoids
  ## JSON's implicit coercion of frame kinds. The payload length is measured in
  ## bytes, matching Nim string indexing and RESP bulk-string semantics.
  result = redisChannelWirePrefix & $ord(message.kind) & ":" &
    $message.closeCode & ":" & $message.payload.len & ":" & message.payload

proc nextField(payload: string, cursor: var int): string =
  let ending = payload.find(':', cursor)
  if ending < 0:
    raise newException(ValueError, "Redis channel envelope is missing a field")
  result = payload[cursor ..< ending]
  cursor = ending + 1

proc decodeRedisChannelMessage*(payload: string): WebSocketMessage =
  ## Decode strictly: accepting trailing bytes would turn a truncated or
  ## concatenated broker payload into a different WebSocket message.
  if not payload.startsWith(redisChannelWirePrefix):
    raise newException(ValueError, "Redis channel envelope prefix is invalid")
  var cursor = redisChannelWirePrefix.len
  let kindValue = parseInt(nextField(payload, cursor))
  let closeCode = parseInt(nextField(payload, cursor))
  let payloadLength = parseInt(nextField(payload, cursor))
  if payloadLength < 0 or payload.len - cursor != payloadLength:
    raise newException(ValueError, "Redis channel envelope payload length is invalid")
  if kindValue < ord(low(WebSocketMessageKind)) or
      kindValue > ord(high(WebSocketMessageKind)):
    raise newException(ValueError, "Redis channel envelope message kind is invalid")
  result.kind = WebSocketMessageKind(kindValue)
  result.closeCode = closeCode
  if payloadLength == 0:
    result.payload = ""
  else:
    result.payload = payload[cursor .. ^1]

proc nextRedisFrame(socket: AsyncSocket,
                   maxFrameBytes: int): Future[string] {.async.} =
  ## A publisher uses a short-lived command socket. Keep its frame reader
  ## local so a blocking RedisValkeyRespClient is never called from the event
  ## loop and subscription framing remains owned by redis_channels.nim.
  var buffer = ""
  while buffer.len < maxFrameBytes:
    var cursor = 0
    try:
      let ending = respFrameEnd(buffer, cursor)
      return buffer[0 ..< ending]
    except ValueError as error:
      if not error.msg.startsWith("incomplete RESP"):
        raise
    let chunk = await socket.recv(1)
    if chunk.len == 0:
      raise newException(CatchableError, "Redis channel publish socket closed")
    buffer.add(chunk)
  raise newException(ValueError, "Redis channel publish response exceeds limit")

type
  RedisChannelLayer* = ref object of ChannelLayer
    ## The pub/sub client owns the long-lived reader; each publish uses a
    ## separate command socket because Redis subscription connections cannot
    ## issue ordinary commands after SUBSCRIBE.
    host*: string
    port*: Port
    maxPendingMessages*: int
    backpressurePolicy*: RedisBackpressurePolicy
    deliveryPolicy*: RedisChannelDeliveryPolicy
    client: RedisPubSubClient
    nextId: int
    localSubscriptions: Table[int, ChannelSubscription]
    remoteSubscriptions: Table[int, RedisPubSubSubscription]
    started: bool
    closed: bool

proc validateRedisChannelLayer(layer: RedisChannelLayer) =
  if layer.isNil or layer.closed:
    raise newException(CatchableError, "Redis channel layer is closed")

proc newRedisChannelLayer*(host = "127.0.0.1", port = Port(6379),
                          maxPendingMessages = 1024,
                          backpressurePolicy = rbpCloseConnection): RedisChannelLayer =
  ## Construction is lazy: connecting belongs to start() so application boot
  ## can validate configuration before any external socket is opened.
  new(result)
  result.host = host
  result.port = port
  result.maxPendingMessages = maxPendingMessages
  result.backpressurePolicy = backpressurePolicy
  result.deliveryPolicy = defaultRedisChannelDeliveryPolicy()
  result.deliveryPolicy.maxPendingMessages = maxPendingMessages
  result.deliveryPolicy.backpressurePolicy = backpressurePolicy
  validateRedisChannelDeliveryPolicy(result.deliveryPolicy)
  result.client = newRedisPubSubClient(host, port,
    maxPendingMessages = maxPendingMessages,
    backpressurePolicy = backpressurePolicy)
  result.localSubscriptions = initTable[int, ChannelSubscription]()
  result.remoteSubscriptions = initTable[int, RedisPubSubSubscription]()

proc newRedisChannelLayer*(deliveryPolicy: RedisChannelDeliveryPolicy,
                           host = "127.0.0.1", port = Port(6379)): RedisChannelLayer =
  ## Prefer this overload when application configuration already has a single
  ## delivery policy.  It prevents the layer and its subscription client from
  ## receiving divergent queue or overflow settings.
  validateRedisChannelDeliveryPolicy(deliveryPolicy)
  new(result)
  result.host = host
  result.port = port
  result.maxPendingMessages = deliveryPolicy.maxPendingMessages
  result.backpressurePolicy = deliveryPolicy.backpressurePolicy
  result.deliveryPolicy = deliveryPolicy
  result.client = newRedisPubSubClient(deliveryPolicy, host, port)
  result.localSubscriptions = initTable[int, ChannelSubscription]()
  result.remoteSubscriptions = initTable[int, RedisPubSubSubscription]()

proc start*(layer: RedisChannelLayer): Future[void] {.async.} =
  validateRedisChannelLayer(layer)
  if layer.started:
    return
  await layer.client.connect()
  layer.started = true

proc stop*(layer: RedisChannelLayer) =
  ## Stop is synchronous and idempotent, matching the underlying socket
  ## client's close contract. Callers that need broker acknowledgements should
  ## unsubscribeAsync before invoking stop during graceful shutdown.
  if layer.isNil or layer.closed:
    return
  layer.closed = true
  layer.started = false
  for subscription in layer.localSubscriptions.values:
    subscription.active = false
  layer.localSubscriptions.clear()
  layer.remoteSubscriptions.clear()
  layer.client.close()

proc nextSubscription(layer: RedisChannelLayer, group: string,
                      subscriber: ChannelSubscriber): ChannelSubscription =
  if group.strip().len == 0:
    raise newException(ValueError, "channel group must not be empty")
  if subscriber.isNil:
    raise newException(ValueError, "channel subscriber must not be nil")
  inc layer.nextId
  result = newChannelSubscription(layer.nextId, group, subscriber)
  layer.localSubscriptions[result.id] = result

proc attachRemote(layer: RedisChannelLayer,
                  subscription: ChannelSubscription): Future[void] {.async.} =
  ## The callback is registered before awaiting the Redis acknowledgement so
  ## a broker that publishes immediately after SUBSCRIBE cannot race local
  ## subscription state.
  let remote = await layer.client.subscribe(subscription.group,
    proc(channel, payload: string): Future[void] {.async, gcsafe.} =
      if channel != subscription.group or not subscription.active:
        return
      await deliverChannelSubscription(subscription,
        decodeRedisChannelMessage(payload)))
  if subscription.active:
    layer.remoteSubscriptions[subscription.id] = remote
  else:
    await layer.client.unsubscribe(remote)

proc attachRemoteSafely(layer: RedisChannelLayer,
                        subscription: ChannelSubscription): Future[void] {.async.} =
  ## The legacy synchronous subscribe method cannot return an async failure;
  ## it still revokes the local capability when its background attach fails.
  try:
    await layer.attachRemote(subscription)
  except CatchableError:
    subscription.active = false
    layer.localSubscriptions.del(subscription.id)

method subscribeAsync*(layer: RedisChannelLayer, group: string,
                       subscriber: ChannelSubscriber): Future[ChannelSubscription] {.async, gcsafe.} =
  validateRedisChannelLayer(layer)
  await layer.start()
  let subscription = nextSubscription(layer, group, subscriber)
  await layer.attachRemote(subscription)
  result = subscription

method subscribe*(layer: RedisChannelLayer, group: string,
                  subscriber: ChannelSubscriber): ChannelSubscription {.gcsafe.} =
  validateRedisChannelLayer(layer)
  let subscription = nextSubscription(layer, group, subscriber)
  ## Preserve the original synchronous ChannelLayer API for adapters such as
  ## WebSocket binding. The async extension remains the deterministic API when
  ## the caller must wait for broker acknowledgement.
  asyncCheck layer.attachRemoteSafely(subscription)
  subscription

method unsubscribeAsync*(layer: RedisChannelLayer,
                         subscription: ChannelSubscription): Future[void] {.async, gcsafe.} =
  validateRedisChannelLayer(layer)
  if subscription.isNil or not subscription.active:
    return
  subscription.active = false
  layer.localSubscriptions.del(subscription.id)
  if layer.remoteSubscriptions.hasKey(subscription.id):
    let remote = layer.remoteSubscriptions[subscription.id]
    layer.remoteSubscriptions.del(subscription.id)
    await layer.client.unsubscribe(remote)

method unsubscribe*(layer: RedisChannelLayer,
                    subscription: ChannelSubscription) {.gcsafe.} =
  if layer.isNil or subscription.isNil or not subscription.active:
    return
  subscription.active = false
  layer.localSubscriptions.del(subscription.id)
  if layer.remoteSubscriptions.hasKey(subscription.id):
    let remote = layer.remoteSubscriptions[subscription.id]
    layer.remoteSubscriptions.del(subscription.id)
    asyncCheck layer.client.unsubscribe(remote)

proc publishRedisChannelAsync(layer: RedisChannelLayer, group: string,
                              message: WebSocketMessage): Future[int] {.async.} =
  validateRedisChannelLayer(layer)
  if group.strip().len == 0:
    raise newException(ValueError, "channel group must not be empty")
  if not layer.started:
    await layer.start()
  let socket = newAsyncSocket(buffered = false)
  try:
    await socket.connect(layer.host, layer.port)
    await socket.send(encodeRedisPublishCommand(group.strip(),
      encodeRedisChannelMessage(message)))
    result = parseRedisIntegerResponse(await nextRedisFrame(socket, 64 * 1024 * 1024))
  finally:
    socket.close()

method publish*(layer: RedisChannelLayer, group: string,
                message: WebSocketMessage): Future[int] {.gcsafe.} =
  publishRedisChannelAsync(layer, group, message)

proc reconnectWithRetry*(layer: RedisChannelLayer, maxAttempts = 3,
                         initialDelayMs = 25,
                         maxDelayMs = 1000): Future[int] {.async.} =
  ## Reconnect delegates retry timing to the socket adapter while this layer
  ## retains local and remote subscription identity. The underlying client
  ## re-subscribes every active group after the new socket is acknowledged.
  validateRedisChannelLayer(layer)
  if not layer.started:
    await layer.start()
    return 1
  await layer.client.reconnectWithRetry(maxAttempts, initialDelayMs, maxDelayMs)

proc reconnectWithPolicy*(layer: RedisChannelLayer,
                          policy: RedisChannelDeliveryPolicy): Future[int] {.async.} =
  ## The layer delegates retry timing to the same policy contract as its
  ## subscription client while retaining ownership of channel re-subscription.
  validateRedisChannelDeliveryPolicy(policy)
  await layer.client.reconnectWithPolicy(policy)

proc shutdown*(layer: RedisChannelLayer): Future[void] {.async.} =
  ## Graceful shutdown drains UNSUBSCRIBE acknowledgements before closing the
  ## socket. This is intentionally separate from stop(), which is the fast
  ## synchronous path for process abort or already-failed transports.
  if layer.isNil or layer.closed:
    return
  try:
    var remoteIds: seq[int] = @[]
    for id in layer.remoteSubscriptions.keys:
      remoteIds.add(id)
    for id in remoteIds:
      if layer.remoteSubscriptions.hasKey(id):
        let remote = layer.remoteSubscriptions[id]
        await layer.client.unsubscribe(remote)
        layer.remoteSubscriptions.del(id)
  finally:
    layer.stop()

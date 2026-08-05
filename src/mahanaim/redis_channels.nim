## Async Redis/Valkey pub/sub subscription adapter.
##
## Publishing remains on the synchronous RESP command client. This module
## owns the distinct long-lived subscription socket, acknowledgement ordering,
## frame coalescing, and local subscriber lifecycle. Keeping those concerns out
## of redis_resp.nim prevents a blocking rate-limit client from being reused in
## an event-loop callback accidentally.

import std/[asyncdispatch, asyncnet, strutils, tables]
import ./redis_resp

type
  RedisPubSubSubscriber* = proc(channel, payload: string): Future[void] {.gcsafe.}

  RedisBackpressurePolicy* = enum
    ## Overflow behavior is explicit because silently dropping realtime data
    ## is unsafe for some applications and preferable for others.
    rbpCloseConnection
    rbpDropNewest
    rbpDropOldest

  RedisChannelDeliveryPolicy* = object
    ## One value object owns the delivery decisions that otherwise tend to be
    ## duplicated across application wiring, worker configuration, and retry
    ## call sites.  The wire adapter still owns socket mechanics; this policy
    ## only describes bounded behavior at that boundary.
    maxPendingMessages*: int
    backpressurePolicy*: RedisBackpressurePolicy
    maxReconnectAttempts*: int
    initialReconnectDelayMs*: int
    maxReconnectDelayMs*: int
    preserveOrdering*: bool

  RedisPubSubSubscription* = ref object
    ## A subscription is local state; Redis only knows the channel membership.
    id*: int
    channel*: string
    active*: bool
    subscriber: RedisPubSubSubscriber

  RedisPubSubClient* = ref object
    host*: string
    port*: Port
    maxFrameBytes*: int
    maxPendingMessages*: int
    backpressurePolicy*: RedisBackpressurePolicy
    droppedMessages*: int
    socket: AsyncSocket
    receiveBuffer: string
    reader: Future[void]
    deliveryTask: Future[void]
    deliveryWake: Future[void]
    pendingMessages: seq[RedisPubSubEvent]
    acknowledgement: Future[RedisPubSubEvent]
    nextId: int
    subscriptions: Table[string, seq[RedisPubSubSubscription]]
    closed: bool

proc defaultRedisChannelDeliveryPolicy*(): RedisChannelDeliveryPolicy =
  ## Safe defaults favor bounded memory, explicit failure, and ordered
  ## delivery.  Applications may choose a drop policy, but must do so
  ## explicitly at composition time.
  RedisChannelDeliveryPolicy(
    maxPendingMessages: 1024,
    backpressurePolicy: rbpCloseConnection,
    maxReconnectAttempts: 3,
    initialReconnectDelayMs: 25,
    maxReconnectDelayMs: 1000,
    preserveOrdering: true)

proc validateRedisChannelDeliveryPolicy*(policy: RedisChannelDeliveryPolicy) =
  ## Fail before connecting so an invalid retry or queue policy cannot become
  ## an operational surprise after the subscription socket is live.
  if policy.maxPendingMessages < 1:
    raise newException(ValueError,
      "Redis channel pending message limit must be positive")
  if policy.maxReconnectAttempts < 1:
    raise newException(ValueError,
      "Redis channel reconnect attempts must be positive")
  if policy.initialReconnectDelayMs < 0 or
      policy.maxReconnectDelayMs < policy.initialReconnectDelayMs:
    raise newException(ValueError,
      "Redis channel reconnect delay bounds are invalid")
  if not policy.preserveOrdering:
    raise newException(ValueError,
      "Redis channel adapter requires ordered delivery")

proc newRedisPubSubClient*(host = "127.0.0.1", port = Port(6379),
                           maxFrameBytes = 64 * 1024 * 1024,
                           maxPendingMessages = 1024,
                           backpressurePolicy = rbpCloseConnection): RedisPubSubClient =
  ## Construct lazily so configuration and compile checks do not require Redis.
  if host.strip().len == 0:
    raise newException(ValueError, "Redis pub/sub host cannot be empty")
  if maxFrameBytes < 1024:
    raise newException(ValueError, "Redis pub/sub frame limit is too small")
  if maxPendingMessages < 1:
    raise newException(ValueError, "Redis pending message limit must be positive")
  new(result)
  result.host = host
  result.port = port
  result.maxFrameBytes = maxFrameBytes
  result.maxPendingMessages = maxPendingMessages
  result.backpressurePolicy = backpressurePolicy
  result.droppedMessages = 0
  result.receiveBuffer = ""
  result.nextId = 0
  result.subscriptions = initTable[string, seq[RedisPubSubSubscription]]()
  result.pendingMessages = @[]
  result.closed = false

proc newRedisPubSubClient*(deliveryPolicy: RedisChannelDeliveryPolicy,
                           host = "127.0.0.1", port = Port(6379),
                           maxFrameBytes = 64 * 1024 * 1024): RedisPubSubClient =
  ## Policy-based construction is the preferred framework boundary.  The
  ## legacy scalar overload remains available for source compatibility, while
  ## this overload keeps related limits together and validates them atomically.
  validateRedisChannelDeliveryPolicy(deliveryPolicy)
  result = newRedisPubSubClient(host, port, maxFrameBytes,
    deliveryPolicy.maxPendingMessages, deliveryPolicy.backpressurePolicy)

proc nextRespFrame(client: RedisPubSubClient): Future[string] {.async.} =
  ## Preserve coalesced RESP frames and wait for partial frames without
  ## guessing whether a pub/sub payload contains textual delimiters.
  while client.receiveBuffer.len < client.maxFrameBytes:
    var cursor = 0
    try:
      let ending = respFrameEnd(client.receiveBuffer, cursor)
      result = client.receiveBuffer[0 ..< ending]
      if ending < client.receiveBuffer.len:
        client.receiveBuffer = client.receiveBuffer[ending .. ^1]
      else:
        client.receiveBuffer = ""
      return
    except ValueError as error:
      if not error.msg.startsWith("incomplete RESP"):
        raise
    let chunk = await client.socket.recv(1)
    if chunk.len == 0:
      raise newException(CatchableError, "Redis pub/sub socket closed")
    client.receiveBuffer.add(chunk)
  raise newException(ValueError, "Redis pub/sub frame exceeds configured limit")

proc signalDelivery(client: RedisPubSubClient) =
  if not client.deliveryWake.isNil and not client.deliveryWake.finished:
    let wake = client.deliveryWake
    client.deliveryWake = nil
    wake.complete()

proc deliverMessage(client: RedisPubSubClient,
                   event: RedisPubSubEvent): Future[void] {.async, gcsafe.} =
  ## Delivery stays sequential per connection, preserving the ordering
  ## contract even while the socket reader continues filling the bounded queue.
  let entries = client.subscriptions.getOrDefault(event.channel, @[])
  for entry in entries:
    if entry.active:
      try:
        await entry.subscriber(event.channel, event.payload)
      except CatchableError:
        ## One local consumer must not poison delivery to the other sessions.
        discard

proc deliveryLoop(client: RedisPubSubClient): Future[void] {.async, gcsafe.} =
  while not client.closed:
    if client.pendingMessages.len == 0:
      client.deliveryWake = newFuture[void]("redisPubSubDelivery")
      await client.deliveryWake
      continue
    let event = client.pendingMessages[0]
    client.pendingMessages.delete(0)
    await client.deliverMessage(event)

proc enqueueMessage(client: RedisPubSubClient, event: RedisPubSubEvent) =
  if client.pendingMessages.len >= client.maxPendingMessages:
    case client.backpressurePolicy
    of rbpCloseConnection:
      client.closed = true
      raise newException(CatchableError,
        "Redis pub/sub pending message limit exceeded")
    of rbpDropNewest:
      inc client.droppedMessages
      return
    of rbpDropOldest:
      client.pendingMessages.delete(0)
      inc client.droppedMessages
  client.pendingMessages.add(event)
  client.signalDelivery()

proc dispatchLoop(client: RedisPubSubClient): Future[void] {.async, gcsafe.} =
  ## One reader owns the socket. This avoids concurrent reads when an ack and
  ## a message arrive in the same TCP packet.
  try:
    while not client.closed:
      let event = parseRedisPubSubEvent(await client.nextRespFrame())
      if event.kind in {rpekSubscribe, rpekUnsubscribe}:
        if not client.acknowledgement.isNil and
            not client.acknowledgement.finished:
          let waiter = client.acknowledgement
          client.acknowledgement = nil
          waiter.complete(event)
      elif event.kind == rpekMessage:
        client.enqueueMessage(event)
  except CatchableError as error:
    if not client.acknowledgement.isNil and
        not client.acknowledgement.finished:
      let waiter = client.acknowledgement
      client.acknowledgement = nil
      waiter.fail(error)
    if not client.closed:
      ## A transport failure is recoverable. Leave intentional close as the
      ## only terminal state; reconnect() can replace this failed socket and
      ## restore every still-active channel membership.
      let brokenSocket = client.socket
      client.socket = nil
      if not brokenSocket.isNil:
        brokenSocket.close()

proc connect*(client: RedisPubSubClient): Future[void] {.async.} =
  if client.isNil:
    raise newException(ValueError, "Redis pub/sub client is required")
  if client.closed:
    raise newException(CatchableError, "Redis pub/sub client is closed")
  if not client.socket.isNil:
    return
  client.socket = newAsyncSocket(buffered = false)
  try:
    await client.socket.connect(client.host, client.port)
  except CatchableError:
    client.socket.close()
    client.socket = nil
    raise
  if client.deliveryTask.isNil or client.deliveryTask.finished:
    client.deliveryTask = deliveryLoop(client)
    asyncCheck client.deliveryTask
  client.reader = dispatchLoop(client)
  asyncCheck client.reader

proc awaitAcknowledgement(client: RedisPubSubClient, command: string,
                          expected: RedisPubSubEventKind,
                          channel: string): Future[void]

proc reconnect*(client: RedisPubSubClient): Future[void] {.async.} =
  ## Reconnect is explicit and bounded by the caller's retry policy. This
  ## operation performs one attempt, then re-subscribes all active channels;
  ## a deployment can wrap it with its own exponential backoff and circuit
  ## breaker without embedding policy in the wire adapter.
  if client.isNil:
    raise newException(ValueError, "Redis pub/sub client is required")
  if client.closed:
    raise newException(CatchableError, "Redis pub/sub client is closed")
  if not client.reader.isNil and not client.reader.finished:
    ## Do not close a socket while asyncnet.recv is pending: Nim's asyncnet
    ## asserts on that race. Reconnect is therefore safe after the peer has
    ## closed the failed connection; callers can use close() for intentional
    ## shutdown instead.
    var waitedMs = 0
    while not client.reader.finished and waitedMs < 5000:
      await sleepAsync(1)
      inc waitedMs
    if not client.reader.finished:
      raise newException(CatchableError,
        "Redis pub/sub reader did not finish before reconnect")
  if not client.socket.isNil:
    client.socket.close()
    client.socket = nil
  client.receiveBuffer = ""
  await client.connect()
  var channels: seq[string] = @[]
  for channel in client.subscriptions.keys:
    channels.add(channel)
  for channel in channels:
    await client.awaitAcknowledgement(encodeRedisSubscribeCommand(channel),
      rpekSubscribe, channel)

proc reconnectWithRetry*(client: RedisPubSubClient, maxAttempts = 3,
                         initialDelayMs = 25,
                         maxDelayMs = 1000): Future[int] {.async.} =
  ## Orchestrate bounded exponential backoff without hiding policy inside
  ## reconnect(). The return value is the successful attempt number, making
  ## retry behavior observable to metrics and deterministic in tests.
  if maxAttempts < 1:
    raise newException(ValueError, "Redis reconnect maxAttempts must be positive")
  if initialDelayMs < 0 or maxDelayMs < initialDelayMs:
    raise newException(ValueError,
      "Redis reconnect delay bounds are invalid")
  var delayMs = initialDelayMs
  for attempt in 1 .. maxAttempts:
    try:
      await client.reconnect()
      return attempt
    except CatchableError:
      if attempt == maxAttempts:
        raise
      if delayMs > 0:
        await sleepAsync(delayMs)
      if delayMs == 0:
        continue
      delayMs = min(maxDelayMs, delayMs * 2)
  raise newException(CatchableError, "Redis reconnect attempts exhausted")

proc reconnectWithPolicy*(client: RedisPubSubClient,
                          policy: RedisChannelDeliveryPolicy): Future[int] {.async.} =
  ## Keep retry orchestration reusable without making callers unpack policy
  ## fields or accidentally omit one of the bounded delay constraints.
  validateRedisChannelDeliveryPolicy(policy)
  await client.reconnectWithRetry(policy.maxReconnectAttempts,
    policy.initialReconnectDelayMs, policy.maxReconnectDelayMs)

proc awaitAcknowledgement(client: RedisPubSubClient, command: string,
                          expected: RedisPubSubEventKind,
                          channel: string): Future[void] {.async.} =
  if not client.acknowledgement.isNil:
    raise newException(CatchableError, "Redis pub/sub acknowledgement is busy")
  ## Keep a local future. The reader clears the shared slot immediately before
  ## completing it, so awaiting the mutable field would create a subtle race
  ## when an acknowledgement arrives in the same event-loop turn.
  let waiter = newFuture[RedisPubSubEvent]("redisPubSubAck")
  client.acknowledgement = waiter
  await client.socket.send(command)
  let event = await waiter
  if event.kind != expected or event.channel != channel:
    raise newException(ValueError, "unexpected Redis pub/sub acknowledgement")

proc subscribe*(client: RedisPubSubClient, channel: string,
                subscriber: RedisPubSubSubscriber): Future[RedisPubSubSubscription] {.async.} =
  validateRedisChannel(channel)
  if subscriber.isNil:
    raise newException(ValueError, "Redis pub/sub subscriber must not be nil")
  await client.connect()
  inc client.nextId
  result = RedisPubSubSubscription(id: client.nextId, channel: channel,
                                   active: true, subscriber: subscriber)
  var entries = client.subscriptions.getOrDefault(channel, @[])
  let first = entries.len == 0
  entries.add(result)
  client.subscriptions[channel] = entries
  if first:
    try:
      await client.awaitAcknowledgement(encodeRedisSubscribeCommand(channel),
        rpekSubscribe, channel)
    except CatchableError:
      result.active = false
      client.subscriptions.del(channel)
      raise

proc unsubscribe*(client: RedisPubSubClient,
                  subscription: RedisPubSubSubscription): Future[void] {.async.} =
  if client.isNil or subscription.isNil or not subscription.active:
    return
  subscription.active = false
  var entries = client.subscriptions.getOrDefault(subscription.channel, @[])
  var retained: seq[RedisPubSubSubscription] = @[]
  for entry in entries:
    if entry != subscription and entry.active:
      retained.add(entry)
  if retained.len == 0:
    client.subscriptions.del(subscription.channel)
    if not client.closed:
      await client.awaitAcknowledgement(
        encodeRedisUnsubscribeCommand(subscription.channel),
        rpekUnsubscribe, subscription.channel)
  else:
    client.subscriptions[subscription.channel] = retained

proc close*(client: RedisPubSubClient) =
  ## Close is idempotent and intentionally synchronous: AsyncSocket.close()
  ## only releases the descriptor; pending futures observe the reader failure.
  if client.isNil or client.closed:
    return
  client.closed = true
  if not client.deliveryWake.isNil and not client.deliveryWake.finished:
    let wake = client.deliveryWake
    client.deliveryWake = nil
    wake.complete()
  client.pendingMessages.setLen(0)
  for channel, entries in client.subscriptions.mpairs:
    discard channel
    for entry in entries.mitems:
      entry.active = false
  client.subscriptions.clear()
  if not client.socket.isNil:
    client.socket.close()
    client.socket = nil

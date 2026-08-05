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
    socket: AsyncSocket
    receiveBuffer: string
    reader: Future[void]
    acknowledgement: Future[RedisPubSubEvent]
    nextId: int
    subscriptions: Table[string, seq[RedisPubSubSubscription]]
    closed: bool

proc newRedisPubSubClient*(host = "127.0.0.1", port = Port(6379),
                           maxFrameBytes = 64 * 1024 * 1024): RedisPubSubClient =
  ## Construct lazily so configuration and compile checks do not require Redis.
  if host.strip().len == 0:
    raise newException(ValueError, "Redis pub/sub host cannot be empty")
  if maxFrameBytes < 1024:
    raise newException(ValueError, "Redis pub/sub frame limit is too small")
  new(result)
  result.host = host
  result.port = port
  result.maxFrameBytes = maxFrameBytes
  result.receiveBuffer = ""
  result.nextId = 0
  result.subscriptions = initTable[string, seq[RedisPubSubSubscription]]()
  result.closed = false

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
        let entries = client.subscriptions.getOrDefault(event.channel, @[])
        for entry in entries:
          if entry.active:
            try:
              await entry.subscriber(event.channel, event.payload)
            except CatchableError:
              ## A disconnected local consumer must not stop the shared reader.
              discard
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
  for channel, entries in client.subscriptions.mpairs:
    discard channel
    for entry in entries.mitems:
      entry.active = false
  client.subscriptions.clear()
  if not client.socket.isNil:
    client.socket.close()
    client.socket = nil

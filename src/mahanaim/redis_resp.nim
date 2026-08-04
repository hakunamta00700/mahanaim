## Redis/Valkey RESP client for distributed fixed-window rate limiting.
##
## The core security policy depends on RateLimitCounterClient, not on a wire
## protocol. This module supplies the concrete transport while keeping RESP
## framing, atomic script semantics, and socket lifecycle independently testable.

import std/[locks, net, strutils]
import ./security

type
  RespCommandTransport* = proc(payload: string): string

  RedisValkeyRespStats* = object
    ## Counters are adapter diagnostics, not rate-limit policy. A snapshot can
    ## be exported to any metrics system without coupling this module to one.
    requests*: int
    successes*: int
    failures*: int
    connections*: int
    reconnects*: int

  RedisValkeyRespClient* = ref object of RateLimitCounterClient
    host*: string
    port*: Port
    timeoutMs*: int
    transport*: RespCommandTransport
    socket: Socket
    lock: Lock
    stats: RedisValkeyRespStats
    everConnected: bool

const fixedWindowScript* =
  "local count = redis.call('INCR', KEYS[1]); " &
  "if count == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]); end; " &
  "return {count, redis.call('TTL', KEYS[1])}"

proc respBulk(value: string): string =
  "$" & $value.len & "\r\n" & value & "\r\n"

proc encodeRedisCommand*(arguments: openArray[string]): string =
  ## All Redis/Valkey commands share one RESP array encoder. Keeping this
  ## primitive public lets cache and queue adapters reuse the same framing
  ## without copying a socket client or inventing a second wire format.
  if arguments.len == 0:
    raise newException(ValueError, "Redis command requires at least one argument")
  result = "*" & $arguments.len & "\r\n"
  for argument in arguments:
    result.add(respBulk(argument))

proc encodeFixedWindowCommand*(key: string, windowSeconds: int): string =
  ## EVAL executes INCR, first-write EXPIRE, and server-side TTL atomically.
  if key.len == 0:
    raise newException(ValueError, "Redis rate limit key cannot be empty")
  if windowSeconds < 1:
    raise newException(ValueError, "Redis rate limit window must be positive")
  let arguments = @[
    "EVAL", fixedWindowScript, "1", key, $windowSeconds]
  encodeRedisCommand(arguments)

proc readRespLine(payload: string, cursor: var int): string =
  let ending = payload.find("\r\n", cursor)
  if ending < 0:
    raise newException(ValueError, "incomplete RESP line")
  result = payload[cursor ..< ending]
  cursor = ending + 2

proc parseCounterResponse*(payload: string): RateLimitCounterResult =
  ## Parse only the response shape emitted by fixedWindowScript. Rejecting all
  ## other RESP values prevents a malformed/error response from being treated
  ## as an allowed request.
  if payload.len == 0:
    raise newException(ValueError, "incomplete RESP response")
  var cursor = 0
  if payload[cursor] == '-':
    inc cursor
    raise newException(CatchableError, "Redis rate limit error: " &
      readRespLine(payload, cursor))
  if payload[cursor] != '*':
    raise newException(ValueError, "unexpected RESP response type")
  inc cursor
  let count = parseInt(readRespLine(payload, cursor))
  if count != 2:
    raise newException(ValueError, "unexpected Redis counter response length")
  var values: array[2, int]
  for index in 0 .. 1:
    if cursor >= payload.len:
      raise newException(ValueError, "incomplete RESP integer")
    if payload[cursor] != ':':
      raise newException(ValueError, "Redis counter response is not integer")
    inc cursor
    values[index] = parseInt(readRespLine(payload, cursor))
  if values[0] < 1 or values[1] < 0:
    raise newException(ValueError, "invalid Redis counter response")
  RateLimitCounterResult(count: values[0], ttlSeconds: values[1])

proc newRedisValkeyRespClient*(host = "127.0.0.1", port = Port(6379),
                               timeoutMs = 5000,
                               transport: RespCommandTransport = nil):
    RedisValkeyRespClient =
  ## Connection is lazy so importing/configuring the adapter does not require
  ## a running Redis server; the first real request establishes the socket.
  if host.strip().len == 0:
    raise newException(ValueError, "Redis host cannot be empty")
  if timeoutMs < 1:
    raise newException(ValueError, "Redis timeout must be positive")
  new(result)
  result.host = host
  result.port = port
  result.timeoutMs = timeoutMs
  result.transport = transport
  result.socket = nil
  result.stats = RedisValkeyRespStats()
  result.everConnected = false
  initLock(result.lock)

proc connectIfNeeded(client: RedisValkeyRespClient) =
  if client.transport != nil:
    return
  if client.socket.isNil:
    client.socket = newSocket()
    try:
      client.socket.connect(client.host, client.port)
      inc client.stats.connections
      if client.everConnected:
        inc client.stats.reconnects
      client.everConnected = true
    except CatchableError:
      client.socket.close()
      client.socket = nil
      raise

proc stats*(client: RedisValkeyRespClient): RedisValkeyRespStats =
  ## Return a copy while holding the same lock as socket operations. This keeps
  ## monitoring snapshots coherent even when several request threads share a
  ## client instance.
  if client.isNil:
    return RedisValkeyRespStats()
  acquire(client.lock)
  try:
    return client.stats
  finally:
    release(client.lock)

proc close*(client: RedisValkeyRespClient) =
  ## Closing a client is idempotent and never affects the security policy's
  ## fail-closed behavior for subsequent calls.
  if client.isNil:
    return
  acquire(client.lock)
  try:
    if not client.socket.isNil:
      client.socket.close()
      client.socket = nil
  finally:
    release(client.lock)

proc respFrameEnd(payload: string, cursor: var int): int =
  ## Find one complete RESP frame without interpreting its application value.
  ## Partial network reads are reported distinctly so callers can continue,
  ## while malformed complete frames fail immediately.
  if cursor >= payload.len:
    raise newException(ValueError, "incomplete RESP frame")
  let kind = payload[cursor]
  inc cursor
  case kind
  of '+', '-', ':':
    discard readRespLine(payload, cursor)
  of '$':
    let length = parseInt(readRespLine(payload, cursor))
    if length < -1:
      raise newException(ValueError, "invalid RESP bulk length")
    if length == -1:
      return cursor
    if cursor + length + 2 > payload.len:
      raise newException(ValueError, "incomplete RESP bulk payload")
    if payload[cursor + length .. cursor + length + 1] != "\r\n":
      raise newException(ValueError, "invalid RESP bulk terminator")
    cursor += length + 2
  of '*':
    let count = parseInt(readRespLine(payload, cursor))
    if count < -1:
      raise newException(ValueError, "invalid RESP array length")
    if count == -1:
      return cursor
    for _ in 0 ..< count:
      discard respFrameEnd(payload, cursor)
  else:
    raise newException(ValueError, "unsupported RESP response type")
  cursor

proc receiveRespFrame(client: RedisValkeyRespClient): string =
  ## Read exactly one generic response frame. The limit bounds memory even if
  ## a remote server sends an unexpectedly large cache value.
  var payload = ""
  while payload.len < 64 * 1024 * 1024:
    let chunk = client.socket.recv(4096, client.timeoutMs)
    if chunk.len == 0:
      raise newException(CatchableError, "Redis connection closed")
    payload.add(chunk)
    var cursor = 0
    try:
      let ending = respFrameEnd(payload, cursor)
      return payload[0 ..< ending]
    except ValueError as error:
      if not error.msg.startsWith("incomplete RESP"):
        raise
  raise newException(ValueError, "Redis RESP response exceeds maximum size")

proc executeCommandLocked(client: RedisValkeyRespClient,
                          command: string): string =
  if client.transport != nil:
    return client.transport(command)
  client.connectIfNeeded()
  client.socket.send(command)
  client.receiveRespFrame()

proc executeCommand*(client: RedisValkeyRespClient, command: string): string =
  ## Execute one arbitrary RESP command using the same bounded retry/reconnect
  ## boundary as the rate-limit operation. Higher-level adapters parse only
  ## the response types they explicitly support.
  if client.isNil or command.len == 0:
    raise newException(ValueError, "Redis command client and command are required")
  acquire(client.lock)
  try:
    inc client.stats.requests
    result = client.executeCommandLocked(command)
    inc client.stats.successes
  except CatchableError:
    inc client.stats.failures
    if client.transport == nil and not client.socket.isNil:
      client.socket.close()
      client.socket = nil
    raise
  finally:
    release(client.lock)

method incrementFixedWindow*(client: RedisValkeyRespClient, key: string,
                             windowSeconds: int): RateLimitCounterResult =
  if client.isNil:
    raise newException(ValueError, "Redis RESP client is required")
  let command = encodeFixedWindowCommand(key, windowSeconds)
  acquire(client.lock)
  try:
    inc client.stats.requests
    result = parseCounterResponse(client.executeCommandLocked(command))
    inc client.stats.successes
    return result
  except CatchableError:
    inc client.stats.failures
    if client.transport == nil and not client.socket.isNil:
      client.socket.close()
      client.socket = nil
    raise
  finally:
    release(client.lock)

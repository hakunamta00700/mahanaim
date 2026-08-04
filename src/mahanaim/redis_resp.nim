## Redis/Valkey RESP client for distributed fixed-window rate limiting.
##
## The core security policy depends on RateLimitCounterClient, not on a wire
## protocol. This module supplies the concrete transport while keeping RESP
## framing, atomic script semantics, and socket lifecycle independently testable.

import std/[locks, net, strutils]
import ./security

type
  RespCommandTransport* = proc(payload: string): string

  RedisValkeyRespClient* = ref object of RateLimitCounterClient
    host*: string
    port*: Port
    timeoutMs*: int
    transport*: RespCommandTransport
    socket: Socket
    lock: Lock

const fixedWindowScript* =
  "local count = redis.call('INCR', KEYS[1]); " &
  "if count == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]); end; " &
  "return {count, redis.call('TTL', KEYS[1])}"

proc respBulk(value: string): string =
  "$" & $value.len & "\r\n" & value & "\r\n"

proc encodeFixedWindowCommand*(key: string, windowSeconds: int): string =
  ## EVAL executes INCR, first-write EXPIRE, and server-side TTL atomically.
  if key.len == 0:
    raise newException(ValueError, "Redis rate limit key cannot be empty")
  if windowSeconds < 1:
    raise newException(ValueError, "Redis rate limit window must be positive")
  let arguments = @[
    "EVAL", fixedWindowScript, "1", key, $windowSeconds]
  result = "*" & $arguments.len & "\r\n"
  for argument in arguments:
    result.add(respBulk(argument))

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
  initLock(result.lock)

proc connectIfNeeded(client: RedisValkeyRespClient) =
  if client.transport != nil:
    return
  if client.socket.isNil:
    client.socket = newSocket()
    try:
      client.socket.connect(client.host, client.port)
    except CatchableError:
      client.socket.close()
      client.socket = nil
      raise

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

proc receiveCounterResponse(client: RedisValkeyRespClient):
    RateLimitCounterResult =
  ## TCP may split even a tiny RESP array across packets. Keep reading only
  ## while the parser reports an incomplete frame; malformed complete frames
  ## fail immediately rather than being retried as if they were network data.
  var payload = ""
  while payload.len < 64 * 1024:
    let chunk = client.socket.recv(4096, client.timeoutMs)
    if chunk.len == 0:
      raise newException(CatchableError, "Redis connection closed")
    payload.add(chunk)
    try:
      return parseCounterResponse(payload)
    except ValueError as error:
      if not error.msg.startsWith("incomplete RESP"):
        raise
  raise newException(ValueError, "Redis RESP response exceeds maximum size")

method incrementFixedWindow*(client: RedisValkeyRespClient, key: string,
                             windowSeconds: int): RateLimitCounterResult =
  if client.isNil:
    raise newException(ValueError, "Redis RESP client is required")
  let command = encodeFixedWindowCommand(key, windowSeconds)
  acquire(client.lock)
  try:
    var response: string
    if client.transport != nil:
      response = client.transport(command)
    else:
      client.connectIfNeeded()
      client.socket.send(command)
      return client.receiveCounterResponse()
    parseCounterResponse(response)
  except CatchableError:
    if client.transport == nil and not client.socket.isNil:
      client.socket.close()
      client.socket = nil
    raise
  finally:
    release(client.lock)

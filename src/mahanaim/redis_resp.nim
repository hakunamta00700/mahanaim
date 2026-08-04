## Redis/Valkey RESP client for distributed fixed-window rate limiting.
##
## The core security policy depends on RateLimitCounterClient, not on a wire
## protocol. This module supplies the concrete transport while keeping RESP
## framing, atomic script semantics, and socket lifecycle independently testable.

import std/[locks, net, strutils]
import ./security

type
  RespCommandTransport* = proc(payload: string): string {.gcsafe.}

  RedisServerFlavor* = enum
    ## INFO exposes a different version key for Redis and Valkey. Keeping the
    ## distinction in the adapter makes compatibility reports actionable
    ## without leaking a vendor-specific client type into security.nim.
    redisFlavor, valkeyFlavor, unknownFlavor

  RedisServerInfo* = object
    flavor*: RedisServerFlavor
    version*: string

  RedisCompatibilityReport* = object
    ## This snapshot describes only capabilities that can be observed through
    ## the portable INFO/CONFIG commands. It is intentionally not a policy
    ## object: rate limiting still owns its fail-closed behavior elsewhere.
    flavor*: RedisServerFlavor
    version*: string
    evictionPolicy*: string
    maxmemoryBytes*: int64
    boundedEviction*: bool
    missingCommands*: seq[string]
    supportsRequiredCommands*: bool

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
    ## TCP can coalesce several RESP replies into one read. Preserve frames
    ## after the first response so a subsequent command never waits for data
    ## that was already received and accidentally discarded.
    receiveBuffer: string
    lock: Lock
    stats: RedisValkeyRespStats
    everConnected: bool

const fixedWindowScript* =
  "local count = redis.call('INCR', KEYS[1]); " &
  "if count == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]); end; " &
  "return {count, redis.call('TTL', KEYS[1])}"

const redisRequiredCommands* = [
  "EVAL", "INCR", "EXPIRE", "TTL", "GET", "SETEX", "SET", "DEL"]

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

proc parseRespBulkString(payload: string, cursor: var int): string =
  ## Parse one bulk string from an already framed RESP payload. Compatibility
  ## probes reject simple strings and nil values so a degraded server response
  ## cannot be mistaken for a valid configuration.
  if cursor >= payload.len or payload[cursor] != '$':
    raise newException(ValueError, "expected RESP bulk string")
  inc cursor
  let lineEnd = payload.find("\r\n", cursor)
  if lineEnd < 0:
    raise newException(ValueError, "incomplete RESP bulk length")
  let length = parseInt(payload[cursor ..< lineEnd])
  cursor = lineEnd + 2
  if length < 0 or cursor + length + 2 > payload.len:
    raise newException(ValueError, "invalid RESP bulk string length")
  result = payload[cursor ..< cursor + length]
  if payload[cursor + length .. cursor + length + 1] != "\r\n":
    raise newException(ValueError, "invalid RESP bulk string terminator")
  cursor += length + 2

proc parseRedisServerInfo*(payload: string): RedisServerInfo =
  ## Parse the stable INFO server fields shared by Redis and Valkey. Unknown
  ## future vendors remain explicit instead of being silently classified.
  var cursor = 0
  let body = parseRespBulkString(payload, cursor)
  for rawLine in body.splitLines():
    let line = rawLine.strip()
    let separator = line.find(':')
    if separator < 1:
      continue
    let key = line[0 ..< separator]
    let value = line[separator + 1 .. ^1]
    case key
    of "redis_version":
      result.flavor = redisFlavor
      result.version = value
    of "valkey_version":
      result.flavor = valkeyFlavor
      result.version = value
    else:
      discard
  if result.version.len == 0:
    result.flavor = unknownFlavor
    raise newException(ValueError, "Redis/Valkey version is missing")

proc parseRedisConfigPair(payload: string, expectedKey: string): string =
  ## CONFIG GET returns [key, value]. Exact key matching guards against a
  ## proxy or ACL wrapper returning a different configuration entry.
  var cursor = 0
  if cursor >= payload.len or payload[cursor] != '*':
    raise newException(ValueError, "expected Redis CONFIG array")
  inc cursor
  let lineEnd = payload.find("\r\n", cursor)
  if lineEnd < 0 or parseInt(payload[cursor ..< lineEnd]) != 2:
    raise newException(ValueError, "Redis CONFIG response must contain two values")
  cursor = lineEnd + 2
  let key = parseRespBulkString(payload, cursor)
  let value = parseRespBulkString(payload, cursor)
  if key != expectedKey:
    raise newException(ValueError, "unexpected Redis CONFIG key: " & key)
  value

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
  result.receiveBuffer = ""
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
    client.receiveBuffer = ""
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
  of '_':
    ## RESP3 null is accepted for command capability probes. The default
    ## client currently speaks RESP2, but accepting this frame keeps the
    ## parser safe when a transport negotiates RESP3 in the future.
    discard readRespLine(payload, cursor)
  else:
    raise newException(ValueError, "unsupported RESP response type")
  cursor

proc receiveRespFrame(client: RedisValkeyRespClient): string =
  ## Read exactly one generic response frame. The limit bounds memory even if
  ## a remote server sends an unexpectedly large cache value.
  var payload = client.receiveBuffer
  while payload.len < 64 * 1024 * 1024:
    var cursor = 0
    try:
      let ending = respFrameEnd(payload, cursor)
      result = payload[0 ..< ending]
      if ending < payload.len:
        client.receiveBuffer = payload[ending .. ^1]
      else:
        client.receiveBuffer = ""
      return
    except ValueError as error:
      if not error.msg.startsWith("incomplete RESP"):
        raise
    ## `net.recv(size, timeout)` does not have identical short-read behavior
    ## across the supported C runtimes. Reading one byte keeps the timeout
    ## contract portable; the frame parser still returns as soon as a complete
    ## RESP value has been accumulated and preserves any following bytes.
    let chunk = client.socket.recv(1, client.timeoutMs)
    if chunk.len == 0:
      raise newException(CatchableError, "Redis connection closed")
    payload.add(chunk)
  raise newException(ValueError, "Redis RESP response exceeds maximum size")

proc executeCommandLocked(client: RedisValkeyRespClient,
                          command: string): string {.gcsafe.} =
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
      client.receiveBuffer = ""
    raise
  finally:
    release(client.lock)

proc parseCommandInfoSupport(payload: string,
                             required: openArray[string]): seq[string] =
  ## COMMAND INFO returns one nested frame per requested command. Preserve the
  ## request order so the result remains deterministic across Redis and Valkey
  ## versions, and treat RESP2 nil/RESP3 null as an unsupported command.
  var cursor = 0
  if cursor >= payload.len or payload[cursor] != '*':
    raise newException(ValueError, "expected Redis COMMAND INFO array")
  inc cursor
  let lineEnd = payload.find("\r\n", cursor)
  if lineEnd < 0:
    raise newException(ValueError, "incomplete Redis COMMAND INFO length")
  let count = parseInt(payload[cursor ..< lineEnd])
  if count != required.len:
    raise newException(ValueError, "Redis COMMAND INFO response length mismatch")
  cursor = lineEnd + 2
  for index in 0 ..< count:
    let frameStart = cursor
    let frameEnd = respFrameEnd(payload, cursor)
    let frame = payload[frameStart ..< frameEnd]
    if frame.len == 0 or frame[0] == '_' or frame.startsWith("$-1") or
        frame.startsWith("*-") or frame.startsWith("*0"):
      result.add(required[index])
  if cursor != payload.len:
    raise newException(ValueError, "trailing Redis COMMAND INFO response")

proc inspectRedisCompatibility*(client: RedisValkeyRespClient):
    RedisCompatibilityReport =
  ## Run the small, read-only compatibility probe used by the operations gate.
  ## CONFIG GET may be restricted by ACL; surfacing that error is preferable to
  ## claiming bounded eviction when the deployment has not been inspected.
  if client.isNil:
    raise newException(ValueError, "Redis compatibility client is required")
  let info = parseRedisServerInfo(client.executeCommand(
    encodeRedisCommand(["INFO", "server"])))
  let evictionPolicy = parseRedisConfigPair(client.executeCommand(
    encodeRedisCommand(["CONFIG", "GET", "maxmemory-policy"])),
    "maxmemory-policy")
  let maxmemoryText = parseRedisConfigPair(client.executeCommand(
    encodeRedisCommand(["CONFIG", "GET", "maxmemory"])), "maxmemory")
  var commandArguments = @["COMMAND", "INFO"]
  for commandName in redisRequiredCommands:
    commandArguments.add(commandName)
  let missingCommands = parseCommandInfoSupport(client.executeCommand(
    encodeRedisCommand(commandArguments)), redisRequiredCommands)
  result.flavor = info.flavor
  result.version = info.version
  result.evictionPolicy = evictionPolicy
  result.maxmemoryBytes = parseBiggestInt(maxmemoryText)
  result.boundedEviction = result.maxmemoryBytes > 0 and
    evictionPolicy.toLowerAscii() != "noeviction"
  result.missingCommands = missingCommands
  result.supportsRequiredCommands = missingCommands.len == 0

method incrementFixedWindow*(client: RedisValkeyRespClient, key: string,
                             windowSeconds: int): RateLimitCounterResult {.gcsafe.} =
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
      client.receiveBuffer = ""
    raise
  finally:
    release(client.lock)

## Dependency-free MessagePack codec for serializer boundary values.
##
## The existing metadata serializer decides which fields are exposed, then
## this module encodes or decodes the resulting JSON AST. Object keys are
## sorted for reproducible cache keys, signatures, snapshots, and tests.

import std/[algorithm, httpcore, json, strutils, tables]
import ./core
import ./response_policy
import ./serialization

type
  MessagePackReader = object
    payload: string
    position: int

proc readByte(reader: var MessagePackReader): uint8 =
  ## Bounds checks turn truncated network payloads into a safe ValueError.
  if reader.position >= reader.payload.len:
    raise newException(ValueError, "MessagePack payload is truncated")
  result = uint8(ord(reader.payload[reader.position]))
  inc reader.position

proc readUnsigned(reader: var MessagePackReader, width: int): uint64 =
  ## MessagePack integers are network-order; no host-endian assumptions leak
  ## into the wire adapter.
  for _ in 0 ..< width:
    result = (result shl 8) or uint64(reader.readByte())

proc readString(reader: var MessagePackReader, length: uint64): string =
  if length > uint64(reader.payload.len - reader.position):
    raise newException(ValueError, "MessagePack string is truncated")
  let finish = reader.position + int(length)
  result = reader.payload[reader.position ..< finish]
  reader.position = finish

proc decodeNode(reader: var MessagePackReader, depth: int): JsonNode

proc decodeCount(reader: var MessagePackReader, width: int): int =
  let count = reader.readUnsigned(width)
  if count > uint64(high(int)):
    raise newException(ValueError, "MessagePack collection is too large")
  count.int

proc decodeNode(reader: var MessagePackReader, depth: int): JsonNode =
  ## A depth bound prevents hostile nested payloads from exhausting the stack.
  if depth > 64:
    raise newException(ValueError, "MessagePack nesting depth is too large")
  let prefix = reader.readByte()
  case prefix
  of 0x00'u8 .. 0x7f'u8:
    result = newJInt(int64(prefix))
  of 0xe0'u8 .. 0xff'u8:
    result = newJInt(int64(cast[int8](prefix)))
  of 0xc0'u8: result = newJNull()
  of 0xc2'u8: result = newJBool(false)
  of 0xc3'u8: result = newJBool(true)
  of 0xcc'u8: result = newJInt(int64(reader.readUnsigned(1)))
  of 0xcd'u8: result = newJInt(int64(reader.readUnsigned(2)))
  of 0xce'u8: result = newJInt(int64(reader.readUnsigned(4)))
  of 0xcf'u8:
    let value = reader.readUnsigned(8)
    if value > uint64(high(int64)):
      raise newException(ValueError, "MessagePack unsigned integer exceeds JSON range")
    result = newJInt(int64(value))
  of 0xd0'u8: result = newJInt(int64(cast[int8](reader.readByte())))
  of 0xd1'u8: result = newJInt(int64(cast[int16](reader.readUnsigned(2))))
  of 0xd2'u8: result = newJInt(int64(cast[int32](reader.readUnsigned(4))))
  of 0xd3'u8: result = newJInt(cast[int64](reader.readUnsigned(8)))
  of 0xca'u8:
    result = newJFloat(float(cast[float32](uint32(reader.readUnsigned(4)))))
  of 0xcb'u8:
    result = newJFloat(cast[float](reader.readUnsigned(8)))
  of 0xa0'u8 .. 0xbf'u8:
    result = newJString(reader.readString(uint64(prefix and 0x1f)))
  of 0xd9'u8:
    result = newJString(reader.readString(reader.readUnsigned(1)))
  of 0xda'u8:
    result = newJString(reader.readString(reader.readUnsigned(2)))
  of 0xdb'u8:
    result = newJString(reader.readString(reader.readUnsigned(4)))
  of 0x90'u8 .. 0x9f'u8:
    result = newJArray()
    for _ in 0 ..< int(prefix and 0x0f):
      result.add(reader.decodeNode(depth + 1))
  of 0xdc'u8, 0xdd'u8:
    result = newJArray()
    let count = reader.decodeCount(if prefix == 0xdc'u8: 2 else: 4)
    for _ in 0 ..< count:
      result.add(reader.decodeNode(depth + 1))
  of 0x80'u8 .. 0x8f'u8:
    result = newJObject()
    for _ in 0 ..< int(prefix and 0x0f):
      let key = reader.decodeNode(depth + 1)
      if key.kind != JString:
        raise newException(ValueError, "MessagePack map key must be a string")
      result[key.getStr()] = reader.decodeNode(depth + 1)
  of 0xde'u8, 0xdf'u8:
    result = newJObject()
    let count = reader.decodeCount(if prefix == 0xde'u8: 2 else: 4)
    for _ in 0 ..< count:
      let key = reader.decodeNode(depth + 1)
      if key.kind != JString:
        raise newException(ValueError, "MessagePack map key must be a string")
      result[key.getStr()] = reader.decodeNode(depth + 1)
  else:
    raise newException(ValueError,
      "Unsupported MessagePack type: 0x" & toHex(int(prefix), 2))

proc addByte(buffer: var string, value: uint8) =
  buffer.add(char(value))

proc addBigEndian(buffer: var string, value: uint64, width: int) =
  for shift in countdown((width - 1) * 8, 0, 8):
    buffer.addByte(uint8((value shr shift) and 0xff))

proc encodeNode(buffer: var string, node: JsonNode)

proc encodeString(buffer: var string, value: string) =
  let length = value.len
  if length <= 31:
    buffer.addByte(uint8(0xA0 or length))
  elif length <= uint8.high.int:
    buffer.addByte(0xD9)
    buffer.addBigEndian(uint64(length), 1)
  elif length <= uint16.high.int:
    buffer.addByte(0xDA)
    buffer.addBigEndian(uint64(length), 2)
  else:
    buffer.addByte(0xDB)
    buffer.addBigEndian(uint64(length), 4)
  buffer.add(value)

proc encodeInteger(buffer: var string, value: int64) =
  ## Use the smallest legal representation while preserving signed values.
  if value >= 0 and value <= 127:
    buffer.addByte(uint8(value))
  elif value >= -32 and value < 0:
    buffer.addByte(uint8(int(value) + 256))
  elif value >= 0 and value <= uint8.high.int:
    buffer.addByte(0xCC)
    buffer.addBigEndian(uint64(value), 1)
  elif value >= 0 and value <= uint16.high.int:
    buffer.addByte(0xCD)
    buffer.addBigEndian(uint64(value), 2)
  elif value >= 0 and value <= uint32.high.int64:
    buffer.addByte(0xCE)
    buffer.addBigEndian(uint64(value), 4)
  elif value >= 0:
    buffer.addByte(0xCF)
    buffer.addBigEndian(uint64(value), 8)
  elif value >= int8.low:
    buffer.addByte(0xD0)
    buffer.addBigEndian(uint64(value and 0xff), 1)
  elif value >= int16.low:
    buffer.addByte(0xD1)
    buffer.addBigEndian(uint64(value and 0xffff), 2)
  elif value >= int32.low:
    buffer.addByte(0xD2)
    buffer.addBigEndian(uint64(value and 0xffffffff), 4)
  else:
    buffer.addByte(0xD3)
    buffer.addBigEndian(cast[uint64](value), 8)

proc encodeArray(buffer: var string, node: JsonNode) =
  if node.len <= 15:
    buffer.addByte(uint8(0x90 or node.len))
  elif node.len <= uint16.high.int:
    buffer.addByte(0xDC)
    buffer.addBigEndian(uint64(node.len), 2)
  else:
    buffer.addByte(0xDD)
    buffer.addBigEndian(uint64(node.len), 4)
  for child in node:
    encodeNode(buffer, child)

proc encodeObject(buffer: var string, node: JsonNode) =
  var keys: seq[string] = @[]
  for key in node.keys:
    keys.add(key)
  keys.sort()
  if keys.len <= 15:
    buffer.addByte(uint8(0x80 or keys.len))
  elif keys.len <= uint16.high.int:
    buffer.addByte(0xDE)
    buffer.addBigEndian(uint64(keys.len), 2)
  else:
    buffer.addByte(0xDF)
    buffer.addBigEndian(uint64(keys.len), 4)
  for key in keys:
    encodeString(buffer, key)
    encodeNode(buffer, node[key])

proc encodeNode(buffer: var string, node: JsonNode) =
  ## JSON has no binary node, so every supported value has one unambiguous wire form.
  if node.isNil:
    buffer.addByte(0xC0)
    return
  case node.kind
  of JNull: buffer.addByte(0xC0)
  of JBool: buffer.addByte(if node.getBool(): 0xC3 else: 0xC2)
  of JInt: encodeInteger(buffer, node.getInt())
  of JFloat:
    buffer.addByte(0xCB)
    buffer.addBigEndian(cast[uint64](node.getFloat()), 8)
  of JString: encodeString(buffer, node.getStr())
  of JArray: encodeArray(buffer, node)
  of JObject: encodeObject(buffer, node)

proc toMessagePack*(node: JsonNode): string =
  ## Return binary bytes in a Nim string; callers choose the HTTP response type.
  result = newStringOfCap(64)
  encodeNode(result, node)

proc fromMessagePack*(payload: string): JsonNode =
  ## Decode one complete JSON-compatible MessagePack document. Rejecting
  ## trailing bytes keeps framing responsibility explicit for stream adapters.
  var reader = MessagePackReader(payload: payload, position: 0)
  result = reader.decodeNode(0)
  if reader.position != payload.len:
    raise newException(ValueError, "MessagePack payload contains trailing bytes")

proc serializeMessagePack*(serialization: SerializationResult): string =
  ## Preserve serializer validation: invalid documents must never be encoded.
  if not serialization.valid:
    raise newException(ValueError, "Cannot encode invalid serialization result")
  serialization.document.toMessagePack()

proc messagePackResponse*(node: JsonNode, status = Http200): Response =
  ## Binary response helper keeps media type explicit for adapter negotiation.
  result = newResponse(status, node.toMessagePack())
  result.headers["content-type"] = "application/msgpack"

proc messagePackResponse*(serialization: SerializationResult,
                          status = Http200): Response =
  ## Refuse invalid DTOs before bytes reach the network boundary.
  result = newResponse(status, serialization.serializeMessagePack())
  result.headers["content-type"] = "application/msgpack"

proc messagePackStreamResponse*(node: JsonNode,
                                status = Http200): Response =
  ## Keep MessagePack bytes on the stream representation boundary so the
  ## network adapters use chunked transfer without making the serializer know
  ## about sockets or event loops.
  streamResponse(node.toMessagePack(), "application/msgpack", status)

proc messagePackStreamResponse*(serialization: SerializationResult,
                                status = Http200): Response =
  ## Validate the shared serialization result before exposing a streaming wire
  ## representation, matching the buffered helper's safety contract.
  if not serialization.valid:
    raise newException(ValueError,
      "Cannot stream an invalid serialization result")
  messagePackStreamResponse(serialization.document, status)

proc negotiateJsonMessagePack*(request: Request, node: JsonNode,
                               status = Http200): Response =
  ## Offer both wire formats from one handler while keeping Accept parsing in
  ## the shared response policy. JSON remains the server preference when the
  ## client does not send an Accept header.
  negotiateResponse(request, [jsonResponse(node, status),
                              messagePackResponse(node, status)])

proc negotiateJsonMessagePack*(request: Request,
                               serialization: SerializationResult,
                               status = Http200): Response =
  ## Invalid DTOs are rejected before either representation reaches negotiation.
  if not serialization.valid:
    raise newException(ValueError,
      "Cannot negotiate an invalid serialization result")
  negotiateJsonMessagePack(request, serialization.document, status)

proc negotiateJsonMessagePackStream*(request: Request, node: JsonNode,
                                     status = Http200): Response =
  ## Offer a buffered JSON representation and a chunked MessagePack
  ## representation through the same Accept policy. The selected wire kind is
  ## visible in Response.representation for every adapter and test client.
  negotiateResponse(request, [jsonResponse(node, status),
                              messagePackStreamResponse(node, status)])

proc negotiateJsonMessagePackStream*(request: Request,
                                     serialization: SerializationResult,
                                     status = Http200): Response =
  ## Keep invalid DTO rejection identical between buffered and stream APIs.
  if not serialization.valid:
    raise newException(ValueError,
      "Cannot negotiate an invalid serialization result")
  negotiateJsonMessagePackStream(request, serialization.document, status)

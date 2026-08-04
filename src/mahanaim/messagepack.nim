## Dependency-free MessagePack encoder for serializer boundary values.
##
## This is intentionally an encoder, not a second object mapper: the existing
## metadata serializer decides which fields are exposed, then this module
## encodes the resulting JSON AST. Object keys are sorted for reproducible
## cache keys, signatures, snapshots, and tests.

import std/[algorithm, json]
import ./serialization

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

proc serializeMessagePack*(serialization: SerializationResult): string =
  ## Preserve serializer validation: invalid documents must never be encoded.
  if not serialization.valid:
    raise newException(ValueError, "Cannot encode invalid serialization result")
  serialization.document.toMessagePack()


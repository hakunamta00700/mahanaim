## Standard-library WebSocket transport adapter.
##
## The core exposes frame values and session callbacks only. This module owns
## the RFC 6455 handshake and frame encoding so that socket details do not
## leak into application handlers or the router.

import std/[asynchttpserver, asyncdispatch, asyncnet, base64, httpcore, options,
            strutils, tables]
import nimcrypto
import ./core
import ./router

const
  websocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  maxWebSocketPayload = 16 * 1024 * 1024

proc socketFd(socket: AsyncSocket): AsyncFD =
  AsyncFD(socket.getFd())

proc recvExactly(socket: AsyncSocket, size: int): Future[string] {.async.} =
  ## TCP reads may be partial; protocol parsing must never assume one recv is
  ## sufficient for a header or payload.
  if size < 0:
    raise newException(ValueError, "WebSocket read size must not be negative")
  while result.len < size:
    let chunk = await socketFd(socket).recv(size - result.len)
    if chunk.len == 0:
      raise newException(IOError, "WebSocket peer closed the connection")
    result.add(chunk)

proc websocketAcceptKey*(clientKey: string): string =
  ## RFC 6455 derives the handshake token from the client nonce plus a fixed
  ## GUID; the digest is encoded as raw bytes before base64 conversion.
  let digest = sha1.digest(clientKey.strip() & websocketGuid)
  base64.encode(digest.data)

proc appendUint16(buffer: var string, value: uint64) =
  buffer.add(char((value shr 8) and 0xff))
  buffer.add(char(value and 0xff))

proc appendUint64(buffer: var string, value: uint64) =
  for shift in countdown(56, 0, 8):
    buffer.add(char((value shr shift) and 0xff))

proc readUint16(value: string): uint64 =
  (uint64(ord(value[0])) shl 8) or uint64(ord(value[1]))

proc readUint64(value: string): uint64 =
  for item in value:
    result = (result shl 8) or uint64(ord(item))

proc sendFrame(socket: AsyncSocket, opcode: byte,
               payload: string): Future[void] {.async.} =
  ## Server frames are never masked. Split the length encoding from payload
  ## writes so large application messages do not require a second copy.
  if payload.len > maxWebSocketPayload:
    raise newException(ValueError, "WebSocket payload exceeds adapter limit")
  var header = newStringOfCap(10)
  header.add(char(0x80 or opcode))
  if payload.len < 126:
    header.add(char(payload.len))
  elif payload.len <= uint16.high.int:
    header.add(char(126))
    appendUint16(header, uint64(payload.len))
  else:
    header.add(char(127))
    appendUint64(header, uint64(payload.len))
  let fd = socketFd(socket)
  await fd.send(header)
  if payload.len > 0:
    await fd.send(payload)

type ParsedFrame = object
  opcode: byte
  payload: string

proc receiveFrame(socket: AsyncSocket): Future[ParsedFrame] {.async.} =
  ## Accept only complete, non-fragmented frames in this first adapter slice.
  ## Fragmentation can be added behind this same session contract later.
  let header = await recvExactly(socket, 2)
  let first = byte(ord(header[0]))
  let second = byte(ord(header[1]))
  if (first and 0x80) == 0:
    raise newException(ValueError, "Fragmented WebSocket frames are unsupported")
  let opcode = first and 0x0f
  let masked = (second and 0x80) != 0
  if not masked:
    raise newException(ValueError, "Client WebSocket frames must be masked")
  var length = uint64(second and 0x7f)
  if length == 126:
    length = readUint16(await recvExactly(socket, 2))
  elif length == 127:
    length = readUint64(await recvExactly(socket, 8))
  if length > uint64(maxWebSocketPayload):
    raise newException(ValueError, "WebSocket payload exceeds adapter limit")
  let mask = await recvExactly(socket, 4)
  let encoded = await recvExactly(socket, int(length))
  result.opcode = opcode
  result.payload = newString(encoded.len)
  for index, value in encoded:
    result.payload[index] = char(ord(value) xor ord(mask[index mod 4]))

proc isWebSocketUpgrade*(request: core.Request): bool =
  ## Header values are already normalized by the HTTP adapter.
  let upgrade = if tables.hasKey(request.headers, "upgrade"): request.headers["upgrade"] else: ""
  let connection = if tables.hasKey(request.headers, "connection"): request.headers["connection"] else: ""
  upgrade.toLowerAscii() == "websocket" and
    connection.toLowerAscii().contains("upgrade") and
    tables.hasKey(request.headers, "sec-websocket-key")

proc newSocketSession(socket: AsyncSocket): WebSocketSession =
  ## Build one adapter-owned session. The handler only sees core message
  ## constructors and cannot accidentally close another request's socket.
  var closed = false
  var writeFrame: proc (opcode: byte, payload: string): Future[void] {.gcsafe.}
  writeFrame = proc(opcode: byte, payload: string): Future[void] {.async, gcsafe.} =
    await sendFrame(socket, opcode, payload)

  let sendMessage: WebSocketSendProc = proc(message: WebSocketMessage): Future[void] {.async, gcsafe.} =
    let opcode = case message.kind
      of wsmText: byte(0x1)
      of wsmBinary: byte(0x2)
      of wsmPing: byte(0x9)
      of wsmPong: byte(0xA)
      of wsmClose: byte(0x8)
    var payload = message.payload
    if message.kind == wsmClose:
      var closePayload = ""
      appendUint16(closePayload, uint64(message.closeCode))
      closePayload.add(message.payload)
      payload = closePayload
    await writeFrame(opcode, payload)

  let receiveMessage: WebSocketReceiveProc = proc(): Future[WebSocketMessage] {.async, gcsafe.} =
    while true:
      let frame = await receiveFrame(socket)
      case frame.opcode
      of 0x1: return textWebSocketMessage(frame.payload)
      of 0x2: return binaryWebSocketMessage(frame.payload)
      of 0x9:
        # RFC 6455 requires an endpoint to answer ping control frames.
        await writeFrame(0xA, frame.payload)
      of 0xA: return controlWebSocketMessage(wsmPong, frame.payload)
      of 0x8:
        if frame.payload.len >= 2:
          return closeWebSocketMessage(int(readUint16(frame.payload[0 .. 1])),
            if frame.payload.len > 2: frame.payload[2 .. ^1] else: "")
        return closeWebSocketMessage()
      else:
        raise newException(ValueError, "Unsupported WebSocket opcode")

  let closeSession: WebSocketCloseProc = proc(code: int,
                                               reason: string): Future[void] {.async, gcsafe.} =
    if closed:
      return
    closed = true
    try:
      var payload = ""
      appendUint16(payload, uint64(code))
      payload.add(reason)
      await writeFrame(0x8, payload)
    finally:
      socket.close()

  newWebSocketSession(sendMessage, receiveMessage, closeSession)

proc serveWebSocket*(socketRequest: asynchttpserver.Request,
                     frameworkRequest: core.Request,
                     route: WebSocketRoute): Future[void] {.async, gcsafe.} =
  ## Complete the HTTP upgrade before invoking user code. Route parameters are
  ## extracted into the same request snapshot used by ordinary handlers.
  if not frameworkRequest.headers.hasKey("sec-websocket-key"):
    await socketRequest.respond(Http400, "Missing WebSocket key")
    return
  let accept = websocketAcceptKey(frameworkRequest.headers["sec-websocket-key"])
  let fd = socketFd(socketRequest.client)
  await fd.send("HTTP/1.1 101 Switching Protocols\c\L" &
    "Upgrade: websocket\c\L" &
    "Connection: Upgrade\c\L" &
    "Sec-WebSocket-Accept: " & accept & "\c\L\c\L")
  var request = frameworkRequest
  let params = extractParams(route.pattern, request.path)
  if params.isSome:
    request.pathParams = params.get()
  let session = newSocketSession(socketRequest.client)
  try:
    await route.handler(request, session)
  finally:
    await session.close()

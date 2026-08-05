##
## The core exposes frame values and session callbacks only. This module owns
## the RFC 6455 handshake and frame encoding so socket details do not leak
## into application handlers or the router.

import std/[asynchttpserver, asyncdispatch, asyncnet, base64, options,
            strutils, tables]
when not defined(windows):
  import pkg/httpx
import nimcrypto
import ./core
import ./router

const
  websocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  maxWebSocketPayload = 16 * 1024 * 1024

type
  WebSocketByteTransport = ref object
    ## Both stdlib AsyncSocket and Beast/httpx SocketHandle implement this
    ## tiny boundary. Frame parsing and session lifecycle stay backend-neutral.
    sendBytes: proc (data: string): Future[void] {.gcsafe.}
    receiveBytes: proc (size: int): Future[string] {.gcsafe.}
    closeSocket: proc () {.gcsafe.}
    when not defined(windows):
      ## Keep the asyncnet owner alive after the httpx callback returns.
      beastSocket: AsyncSocket

  ParsedFrame = object
    fin: bool
    opcode: byte
    payload: string

proc socketFd(socket: AsyncSocket): AsyncFD =
  AsyncFD(socket.getFd())

proc recvExactly(transport: WebSocketByteTransport,
                 size: int): Future[string] {.async.} =
  ## TCP reads may be partial; never assume one recv contains one frame field.
  if size < 0:
    raise newException(ValueError, "WebSocket read size must not be negative")
  while result.len < size:
    let chunk = await transport.receiveBytes(size - result.len)
    if chunk.len == 0:
      raise newException(IOError, "WebSocket peer closed the connection")
    result.add(chunk)

proc websocketAcceptKey*(clientKey: string): string =
  ## RFC 6455 derives the handshake token from nonce plus its fixed GUID.
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

proc sendFrame(transport: WebSocketByteTransport, opcode: byte,
               payload: string): Future[void] {.async.} =
  ## Server frames are never masked and use the RFC 6455 length encoding.
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
  await transport.sendBytes(header)
  if payload.len > 0:
    await transport.sendBytes(payload)

proc receiveFrame(transport: WebSocketByteTransport): Future[ParsedFrame] {.async.} =
  ## Parse one RFC 6455 frame. Message reassembly is intentionally handled by
  ## receiveMessage so control frames can be serviced between fragments.
  let header = await recvExactly(transport, 2)
  let first = byte(ord(header[0]))
  let second = byte(ord(header[1]))
  if (first and 0x70) != 0:
    raise newException(ValueError, "WebSocket reserved bits are unsupported")
  result.fin = (first and 0x80) != 0
  let opcode = first and 0x0f
  if (second and 0x80) == 0:
    raise newException(ValueError, "Client WebSocket frames must be masked")
  var length = uint64(second and 0x7f)
  if length == 126:
    length = readUint16(await recvExactly(transport, 2))
  elif length == 127:
    length = readUint64(await recvExactly(transport, 8))
  if length > uint64(maxWebSocketPayload):
    raise newException(ValueError, "WebSocket payload exceeds adapter limit")
  if opcode >= 0x8 and (not result.fin or length > 125):
    raise newException(ValueError, "Invalid fragmented or oversized control frame")
  let mask = await recvExactly(transport, 4)
  let encoded = await recvExactly(transport, int(length))
  result.opcode = opcode
  result.payload = newString(encoded.len)
  for index, value in encoded:
    result.payload[index] = char(ord(value) xor ord(mask[index mod 4]))

proc isWebSocketUpgrade*(request: core.Request): bool =
  ## Header values are already normalized by every HTTP adapter.
  let upgrade = if tables.hasKey(request.headers, "upgrade"): request.headers["upgrade"] else: ""
  let connection = if tables.hasKey(request.headers, "connection"): request.headers["connection"] else: ""
  upgrade.toLowerAscii() == "websocket" and
    connection.toLowerAscii().contains("upgrade") and
    tables.hasKey(request.headers, "sec-websocket-key")

proc newSocketSession(transport: WebSocketByteTransport): WebSocketSession =
  ## The session owns callbacks, while core handlers never see socket types.
  var closed = false
  let writeFrame: proc (opcode: byte, payload: string): Future[void] {.gcsafe.} =
    proc(opcode: byte, payload: string): Future[void] {.async, gcsafe.} =
      await sendFrame(transport, opcode, payload)

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
    ## A logical message may span one initial data frame and any number of
    ## continuation frames. Control frames are independent of fragmentation;
    ## responding to ping here prevents an interleaved heartbeat from being
    ## delivered as application data.
    var messageOpcode: byte = 0
    var messagePayload = ""
    while true:
      let frame = await receiveFrame(transport)
      case frame.opcode
      of 0x0:
        if messageOpcode == 0:
          raise newException(ValueError, "Unexpected WebSocket continuation")
      of 0x1, 0x2:
        if messageOpcode != 0:
          raise newException(ValueError, "Nested WebSocket data frame")
        messageOpcode = frame.opcode
      of 0x9:
        # RFC 6455 requires an endpoint to answer ping control frames.
        await writeFrame(0xA, frame.payload)
        continue
      of 0xA:
        if messageOpcode == 0:
          return controlWebSocketMessage(wsmPong, frame.payload)
        continue
      of 0x8:
        if frame.payload.len >= 2:
          return closeWebSocketMessage(int(readUint16(frame.payload[0 .. 1])),
            if frame.payload.len > 2: frame.payload[2 .. ^1] else: "")
        return closeWebSocketMessage()
      else:
        raise newException(ValueError, "Unsupported WebSocket opcode")
      messagePayload.add(frame.payload)
      if messagePayload.len > maxWebSocketPayload:
        raise newException(ValueError, "WebSocket message exceeds adapter limit")
      if frame.fin:
        if messageOpcode == 0:
          raise newException(ValueError, "WebSocket message has no data opcode")
        if messageOpcode == 0x1:
          return textWebSocketMessage(messagePayload)
        return binaryWebSocketMessage(messagePayload)

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
      transport.closeSocket()

  newWebSocketSession(sendMessage, receiveMessage, closeSession)

proc serveWebSocketTransport(transport: WebSocketByteTransport,
                             frameworkRequest: core.Request,
                             route: WebSocketRoute): Future[void] {.async, gcsafe.} =
  ## Complete the handshake, then delegate the live session to the route.
  if not frameworkRequest.headers.hasKey("sec-websocket-key"):
    await transport.sendBytes("HTTP/1.1 400 Bad Request\c\L\c\L")
    return
  let accept = websocketAcceptKey(frameworkRequest.headers["sec-websocket-key"])
  await transport.sendBytes("HTTP/1.1 101 Switching Protocols\c\L" &
    "Upgrade: websocket\c\L" &
    "Connection: Upgrade\c\L" &
    "Sec-WebSocket-Accept: " & accept & "\c\L\c\L")
  var request = frameworkRequest
  let params = extractParams(route.pattern, request.path)
  if params.isSome:
    request.pathParams = params.get()
  let session = newSocketSession(transport)
  try:
    await route.handler(request, session)
  finally:
    await session.close()

proc stdTransport(socket: AsyncSocket,
                  closeOnSession: bool): WebSocketByteTransport =
  ## Adapt stdlib's owned AsyncSocket without exposing it to core handlers.
  let fd = socketFd(socket)
  new(result)
  result.sendBytes = proc(data: string): Future[void] {.async, gcsafe.} =
    await fd.send(data)
  result.receiveBytes = proc(size: int): Future[string] {.async, gcsafe.} =
    return await fd.recv(size)
  result.closeSocket = proc() {.gcsafe.} =
    ## An AsyncHttpServer parent may still own this descriptor after the
    ## callback returns. In that mode the parent performs the final close;
    ## direct adapters retain the session-owned close behavior.
    if closeOnSession:
      fd.closeSocket()

proc serveWebSocket*(socketRequest: asynchttpserver.Request,
                     frameworkRequest: core.Request,
                     route: WebSocketRoute,
                     closeOnSession = true): Future[void] {.async, gcsafe.} =
  ## stdlib adapter entry point. The network server can defer final close to
  ## its request parent while standalone callers retain session ownership.
  await serveWebSocketTransport(stdTransport(socketRequest.client,
    closeOnSession),
    frameworkRequest, route)

when not defined(windows):
  proc beastTransport(request: httpx.Request): WebSocketByteTransport =
    ## httpx exposes a raw SocketHandle and requires `forget()` before this
    ## adapter takes over reads and writes for a WebSocket session.
    let fd = AsyncFD(request.client)
    request.forget()
    ## httpx and asyncdispatch have separate selector ownership.  Removing
    ## the descriptor from httpx is not enough; register it before asyncnet
    ## operations or epoll rejects the first send/receive as unregistered.
    asyncdispatch.register(fd)
    let socket = newAsyncSocket(fd, buffered = false)
    new(result)
    result.beastSocket = socket
    result.sendBytes = proc(data: string): Future[void] {.async, gcsafe.} =
      ## httpx waits on its own selector and only polls asyncdispatch when its
      ## dispatcher fd is readable. Pump the handoff-owned dispatcher while a
      ## WebSocket frame is pending, otherwise a writable socket can wait
      ## forever inside the httpx callback.
      let pending = socket.send(data)
      while not pending.finished:
        asyncdispatch.poll(10)
      await pending
    result.receiveBytes = proc(size: int): Future[string] {.async, gcsafe.} =
      ## The same pump is required for reads after httpx has forgotten the fd.
      let pending = socket.recv(size)
      while not pending.finished:
        asyncdispatch.poll(10)
      return await pending
    result.closeSocket = proc() {.gcsafe.} = fd.closeSocket()

  proc serveWebSocket*(socketRequest: httpx.Request,
                       frameworkRequest: core.Request,
                       route: WebSocketRoute): Future[void] {.async, gcsafe.} =
    ## Beast/httpx entry point shares the exact handshake and frame contract.
    await serveWebSocketTransport(beastTransport(socketRequest),
      frameworkRequest, route)

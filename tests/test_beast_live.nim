## Linux-only wire fixture for the Beast/httpx WebSocket ownership boundary.
##
## The server and client modes intentionally live in one executable so the
## fixture can run in a minimal Nim container without another WebSocket tool.

import std/[asyncdispatch, net, options, os, strutils, tables]
import pkg/httpx
import mahanaim/[core, websocket_adapter]

const fixturePort = Port(19091)

proc markerPath(): string =
  getEnv("MAHANAIM_BEAST_MARKER", "tests/.beast-live-complete")

proc websocketHandler(request: core.Request,
                      session: WebSocketSession): Future[void] {.async, gcsafe.} =
  ## Echo one application message, then let the adapter own final close.
  let message = await session.receive()
  doAssert message.kind == wsmText
  await session.send(textWebSocketMessage("echo:" & message.payload))
  let closeMessage = await session.receive()
  doAssert closeMessage.kind == wsmClose
  writeFile(markerPath(), "handler-finalized\n")

proc toFrameworkRequest(request: httpx.Request): core.Request =
  ## Convert only the fields needed by this low-level adapter fixture.
  result = newRequest($request.httpMethod.get(), request.path.get())
  for key, value in request.headers.get():
    result.headers[key.toLowerAscii()] = value

proc onRequest(request: httpx.Request): Future[void] {.async, gcsafe.} =
  ## The callback deliberately hands the raw socket to the Beast adapter.
  let frameworkRequest = toFrameworkRequest(request)
  let route = WebSocketRoute(pattern: "/echo", name: "fixture",
                             handler: websocketHandler)
  try:
    await serveWebSocket(request, frameworkRequest, route)
  except CatchableError:
    ## A client that is killed during readiness probing must not tear down
    ## httpx's accept loop; production adapters also isolate peer resets.
    discard

proc runServer() =
  ## httpx owns accept/read readiness until Request.forget transfers it.
  if fileExists(markerPath()):
    removeFile(markerPath())
  run(onRequest, Settings(port: fixturePort, bindAddr: "127.0.0.1"))

proc recvExactly(socket: Socket, size: int): string =
  while result.len < size:
    let chunk = socket.recv(size - result.len)
    if chunk.len == 0:
      raise newException(IOError, "fixture peer closed early")
    result.add(chunk)

proc maskedFrame(opcode: byte, payload: string): string =
  ## Client frames must be masked; a fixed key keeps the fixture deterministic.
  const mask = [byte(0x12), byte(0x34), byte(0x56), byte(0x78)]
  result.add(char(0x80 or opcode))
  doAssert payload.len < 126
  result.add(char(0x80 or payload.len))
  for value in mask:
    result.add(char(value))
  for index, value in payload:
    result.add(char(ord(value) xor int(mask[index mod mask.len])))

proc runClient() =
  ## Exercise handshake, a masked data frame, and orderly close on the wire.
  ## Use unbuffered reads because the HTTP handshake is shorter than the
  ## scratch buffer; buffered `net.recv` intentionally waits for the full size.
  var socket = newSocket(buffered = false)
  socket.connect("127.0.0.1", fixturePort)
  let clientKey = "dGhlIHNhbXBsZSBub25jZQ=="
  socket.send("GET /echo HTTP/1.1\r\n" &
             "Host: localhost\r\n" &
             "Upgrade: websocket\r\n" &
             "Connection: Upgrade\r\n" &
             "Sec-WebSocket-Version: 13\r\n" &
             "Sec-WebSocket-Key: " & clientKey & "\r\n\r\n")
  var handshake = ""
  while not handshake.contains("\r\n\r\n"):
    let chunk = socket.recv(256)
    if chunk.len == 0:
      raise newException(IOError, "fixture handshake closed early")
    handshake.add(chunk)
  doAssert handshake.startsWith("HTTP/1.1 101 Switching Protocols")
  doAssert handshake.contains("Sec-WebSocket-Accept: " & websocketAcceptKey(clientKey))

  socket.send(maskedFrame(0x1, "hello"))
  let echoHeader = recvExactly(socket, 2)
  doAssert byte(ord(echoHeader[0])) == 0x81
  doAssert byte(ord(echoHeader[1])) == 10
  doAssert recvExactly(socket, 10) == "echo:hello"

  socket.send(maskedFrame(0x8, "\x03\xE8"))
  let closeHeader = recvExactly(socket, 2)
  doAssert byte(ord(closeHeader[0])) == 0x88
  doAssert byte(ord(closeHeader[1])) == 2
  doAssert recvExactly(socket, 2) == "\x03\xE8"
  socket.close()

proc runProbe() =
  ## Separate listener readiness from the slower HTTP/WebSocket assertion.
  var socket = newSocket()
  socket.connect("127.0.0.1", fixturePort)
  socket.close()

when isMainModule:
  if paramCount() > 0 and paramStr(1) == "server":
    runServer()
  elif paramCount() > 0 and paramStr(1) == "client":
    runClient()
  elif paramCount() > 0 and paramStr(1) == "probe":
    runProbe()
  else:
    quit("usage: test_beast_live server|probe|client", QuitFailure)

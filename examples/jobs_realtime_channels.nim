## Executable jobs, SSE, WebSocket, and channel-layer documentation example.
##
## The Redis layer is deliberately constructed but not started: external
## delivery needs a disposable Redis/Valkey service and the redisLive gate.

import std/[asyncdispatch, atomics, strutils, tables]
import mahanaim

proc main() =
  let app = newTestApplication()

  app.get("/events", "events",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      discard request
      return sseResponse([SseEvent(event: "ready", id: "one", retryMs: 500,
        data: "jobs-ready")]))
  app.websocket("/rooms/:room", "room",
    proc(request: Request, session: WebSocketSession): Future[void]
        {.async, gcsafe.} =
      let incoming = await session.receive()
      await session.send(textWebSocketMessage(
        request.pathParams.getOrDefault("room") & ":" & incoming.payload))
      await session.close(1000, "done"))

  let client = newTestClient(app)
  let events = waitFor client.getSseEvents("/events")
  doAssert events.len == 1
  doAssert events[0].event == "ready"
  doAssert events[0].data == "jobs-ready"
  let socket = client.connectWebSocket("/rooms/42")
  waitFor socket.send(textWebSocketMessage("hello"))
  doAssert (waitFor socket.receive()).payload == "42:hello"
  doAssert (waitFor socket.receive()).kind == wsmClose
  waitFor socket.wait()

  var executions: Atomic[int]
  executions.store(0)
  let store = newSqliteDurableJobStore()
  defer: store.close()
  let registry = newDurableJobRegistry()
  registry.registerHandler("email",
    proc(payload: string) {.gcsafe.} =
      doAssert payload == "welcome"
      discard executions.fetchAdd(1))
  store.enqueue("welcome-42", "email", "welcome")
  let run = waitFor registry.runNext(store, app.jobs)
  doAssert run.processed and run.succeeded
  doAssert executions.load() == 1

  let layer = newInMemoryChannelLayer()
  var deliveries: Atomic[int]
  deliveries.store(0)
  let subscription = layer.subscribe("room:42",
    proc(message: WebSocketMessage): Future[void] {.async, gcsafe.} =
      doAssert message.payload == "announcement"
      discard deliveries.fetchAdd(1))
  doAssert (waitFor layer.publish("room:42",
    textWebSocketMessage("announcement"))) == 1
  layer.unsubscribe(subscription)
  doAssert deliveries.load() == 1

  let redisConfiguration = newRedisChannelLayer("127.0.0.1")
  doAssert redisConfiguration.maxPendingMessages == 1024
  redisConfiguration.stop()
  echo "jobs-realtime-channels-ok"

when isMainModule:
  main()

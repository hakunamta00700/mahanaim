## Live Redis/Valkey compatibility contract.
##
## The test intentionally accepts connection settings through environment
## variables so CI can provide a service container without embedding secrets or
## making the framework test suite depend on a particular local daemon.

import std/[asyncdispatch, net, os, osproc, strutils, times]
import mahanaim/[core, redis_channel_layer]
import mahanaim/redis_resp

proc runRedisChannelWorker(host, portText, channel, readyPath,
                           resultPath, stopPath: string) =
  ## A worker is a real child process rather than a second async object in the
  ## parent. This makes the live contract prove process isolation, readiness,
  ## message delivery, and graceful shutdown independently.
  proc run(): Future[void] {.async.} =
    let layer = newRedisChannelLayer(host, Port(parseInt(portText)),
      maxPendingMessages = 16)
    await layer.start()
    discard await layer.subscribeAsync(channel,
      proc(message: WebSocketMessage): Future[void] {.async, gcsafe.} =
        if message.kind != wsmText:
          raise newException(ValueError, "Redis worker received wrong message kind")
        writeFile(resultPath, message.payload)
        await sleepAsync(1))
    writeFile(readyPath, "ready")
    while not fileExists(stopPath):
      await sleepAsync(10)
    await layer.shutdown()
  waitFor run()

proc waitForLiveFile(path: string, timeoutMs = 5000): Future[void] {.async.} =
  var elapsed = 0
  while not fileExists(path) and elapsed < timeoutMs:
    await sleepAsync(10)
    inc elapsed, 10
  if not fileExists(path):
    raise newException(ValueError, "Redis cross-process worker timed out: " & path)

proc runLiveCrossProcessContract(host: string, port: Port): Future[void] {.async.} =
  ## Start two independent OS processes and use one parent publisher. The
  ## channel adapter must not rely on shared Nim heap state to fan out data.
  let root = joinPath(getTempDir(),
    "mahanaim-redis-cross-process-" & $getCurrentProcessId())
  createDir(root)
  let channel = "mahanaim:live:cross-process:" & $epochTime()
  let workerExecutable = getAppFilename()
  var workers: seq[Process] = @[]
  var stopPaths: seq[string] = @[]
  try:
    for index in 1 .. 2:
      let readyPath = joinPath(root, "worker" & $index & ".ready")
      let resultPath = joinPath(root, "worker" & $index & ".result")
      let stopPath = joinPath(root, "worker" & $index & ".stop")
      stopPaths.add(stopPath)
      workers.add(startProcess(workerExecutable, args = [
        "redis-worker", host, $port.int, channel, readyPath, resultPath, stopPath],
        options = {poUsePath, poStdErrToStdOut}))
    for index in 0 ..< 2:
      await waitForLiveFile(joinPath(root, "worker" & $(index + 1) & ".ready"))

    let publisher = newRedisChannelLayer(host, port)
    await publisher.start()
    let subscribers = await publisher.publish(channel,
      textWebSocketMessage("cross-process-payload"))
    if subscribers != 2:
      raise newException(ValueError,
        "Redis cross-process fan-out expected two subscribers, got " & $subscribers)
    for index in 0 ..< 2:
      let resultPath = joinPath(root, "worker" & $(index + 1) & ".result")
      await waitForLiveFile(resultPath)
      if readFile(resultPath) != "cross-process-payload":
        raise newException(ValueError, "Redis cross-process payload mismatch")
    await publisher.shutdown()
  finally:
    for stopPath in stopPaths:
      writeFile(stopPath, "stop")
    for worker in workers:
      discard worker.waitForExit(5000)
      worker.close()
    if dirExists(root):
      removeDir(root)

proc runLiveFanoutContract(host: string, port: Port): Future[void] {.async.} =
  ## Use two independent long-lived subscription sockets. This is the live
  ## broker boundary: Redis must fan one publish out to both consumers, while
  ## each local client retains its own acknowledgement and delivery lifecycle.
  let channel = "mahanaim:live:fanout:" & $epochTime()
  let first = newRedisChannelLayer(host, port, maxPendingMessages = 16)
  let second = newRedisChannelLayer(host, port, maxPendingMessages = 16)
  var deliveries = 0
  let completed = newFuture[void]("redisLiveFanout")
  defer:
    first.stop()
    second.stop()

  await first.start()
  await second.start()
  let firstSubscription = await first.subscribeAsync(channel,
    proc(message: WebSocketMessage): Future[void] {.async, gcsafe.} =
      if message.kind != wsmText or message.payload != "fanout-payload":
        raise newException(ValueError, "Redis live fan-out payload contract failed")
      inc deliveries
      if deliveries == 2 and not completed.finished:
        completed.complete())
  let secondSubscription = await second.subscribeAsync(channel,
    proc(message: WebSocketMessage): Future[void] {.async, gcsafe.} =
      if message.kind != wsmText or message.payload != "fanout-payload":
        raise newException(ValueError, "Redis live fan-out payload contract failed")
      inc deliveries
      if deliveries == 2 and not completed.finished:
        completed.complete())
  let subscribers = await first.publish(channel,
    textWebSocketMessage("fanout-payload"))
  if subscribers != 2:
    raise newException(ValueError,
      "Redis live fan-out expected two subscribers, got " & $subscribers)
  if not await completed.withTimeout(2000):
    raise newException(ValueError, "Redis live fan-out delivery timed out")
  discard firstSubscription
  discard secondSubscription
  await first.shutdown()
  await second.shutdown()

proc runLiveContract() =
  ## Keep missing-service behavior explicit: compile gates prove the source
  ## contract, while this executable is opt-in for CI or a local matrix run.
  let host = getEnv("MAHANAIM_REDIS_HOST")
  let portText = getEnv("MAHANAIM_REDIS_PORT")
  if host.len == 0 or portText.len == 0:
    echo "Redis/Valkey live test skipped: connection settings are not configured"
    quit(0)
  let port = Port(parseInt(portText))
  let client = newRedisValkeyRespClient(host, port, timeoutMs = 2000)
  defer: client.close()

  let ping = client.executeCommand(encodeRedisCommand(["PING"]))
  if not ping.startsWith("+PONG"):
    raise newException(ValueError, "Redis/Valkey live PING contract failed")
  if getEnv("MAHANAIM_REDIS_CONFIGURE") == "true":
    ## CI owns an isolated service container, so it may establish the bounded
    ## eviction policy required by this contract. External environments must
    ## opt in explicitly; a framework test must never mutate an ambient Redis.
    let maxMemory = client.executeCommand(encodeRedisCommand([
      "CONFIG", "SET", "maxmemory", "64mb"]))
    let eviction = client.executeCommand(encodeRedisCommand([
      "CONFIG", "SET", "maxmemory-policy", "allkeys-lru"]))
    if not maxMemory.startsWith("+OK") or not eviction.startsWith("+OK"):
      raise newException(ValueError,
        "Redis/Valkey live fixture could not configure bounded eviction")
  let report = inspectRedisCompatibility(client)
  if report.version.len == 0 or report.flavor == unknownFlavor:
    raise newException(ValueError, "Redis/Valkey live flavor or version is missing")
  if not report.supportsRequiredCommands:
    raise newException(ValueError,
      "Redis/Valkey live command gap: " & $report.missingCommands)
  if not report.boundedEviction:
    raise newException(ValueError,
      "Redis/Valkey live server must configure bounded eviction")

  ## This request crosses the real socket and proves server-side TTL framing,
  ## while the compatibility probe above proves the configured eviction gate.
  let counter = client.incrementFixedWindow("mahanaim:live:compatibility", 30)
  if counter.count < 1 or counter.ttlSeconds < 0 or counter.ttlSeconds > 30:
    raise newException(ValueError, "Redis/Valkey live TTL contract failed")
  waitFor runLiveFanoutContract(host, port)
  waitFor runLiveCrossProcessContract(host, port)
  echo "Redis/Valkey live contract passed: " & $report.flavor & " " &
    report.version

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "redis-worker":
    if params.len != 7:
      raise newException(ValueError, "Redis worker arguments are invalid")
    runRedisChannelWorker(params[1], params[2], params[3], params[4],
      params[5], params[6])
  else:
    runLiveContract()

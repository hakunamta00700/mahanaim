## Live Redis/Valkey compatibility contract.
##
## The test intentionally accepts connection settings through environment
## variables so CI can provide a service container without embedding secrets or
## making the framework test suite depend on a particular local daemon.

import std/[net, os, strutils]
import mahanaim/redis_resp

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
  echo "Redis/Valkey live contract passed: " & $report.flavor & " " &
    report.version

when isMainModule:
  runLiveContract()

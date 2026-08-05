## Deterministic framework HTTP dispatch benchmark.
##
## This workload measures Application.dispatch through routing, security
## middleware, handler invocation, and response creation. It deliberately does
## not claim to measure socket or production network latency; those are covered
## by the live-server and deployment gates.

import std/[asyncdispatch, httpcore, monotimes, times]
import mahanaim/[application, core, security]

const
  DispatchCount = 10_000

proc main() =
  ## Disable the bounded rate-limit policy only for this deterministic workload;
  ## the default security policy remains unchanged in the framework itself.
  var securityPolicy = defaultSecurityPolicy()
  securityPolicy.rateLimitRequests = 0
  let app = newApplication(securityPolicy = securityPolicy)
  app.get("/benchmark", "benchmark",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      ## Keep handler work constant so the measurement represents dispatch
      ## overhead rather than business logic or allocation variability.
      discard request
      return textResponse("dispatch-ok"))

  var dispatched = 0
  var responseBytes = 0
  let started = getMonoTime()
  for _ in 0 ..< DispatchCount:
    let response = waitFor app.dispatch(newRequest("GET", "/benchmark"))
    doAssert response.status == Http200
    doAssert response.body == "dispatch-ok"
    inc dispatched
    responseBytes += response.body.len
  let elapsed = getMonoTime() - started

  ## Correctness remains the invariant; no machine-specific latency threshold
  ## is imposed on CI or developer workstations.
  doAssert dispatched == DispatchCount
  doAssert responseBytes == DispatchCount * "dispatch-ok".len
  echo "dispatches=" & $dispatched &
    " response_bytes=" & $responseBytes &
    " elapsed_ms=" & $elapsed.inMilliseconds

when isMainModule:
  main()

## Deterministic router benchmark.
##
## This executable is intentionally separate from correctness tests: it gives
## route-index changes a repeatable workload without making CI depend on a
## machine-specific latency threshold.

import std/[monotimes, options, times]
import mahanaim/router

const
  RouteCount = 2_000
  IterationCount = 20_000

proc main() =
  var router = initRouter()
  for index in 0 ..< RouteCount:
    router.addRoute("GET", "/api/v" & $index & "/users/:id", "", nil)
  router.addRoute("GET", "/api/v1999/users/me", "", nil)

  var matched = 0
  let indexStats = router.routeIndexStats()
  doAssert indexStats.longestStaticEdgeSegments >= 2
  let started = getMonoTime()
  for index in 0 ..< IterationCount:
    let path = "/api/v" & $(index mod RouteCount) & "/users/42"
    if router.findPath(path).isSome:
      inc matched
  let elapsed = getMonoTime() - started

  ## A benchmark that silently stops finding routes is worse than a slower
  ## benchmark, so keep this workload self-validating.
  doAssert matched == IterationCount
  echo "routes=" & $RouteCount &
    " iterations=" & $IterationCount &
    " matched=" & $matched &
    " static_edges=" & $indexStats.staticEdgeCount &
    " longest_static_edge_segments=" & $indexStats.longestStaticEdgeSegments &
    " elapsed_ms=" & $elapsed.inMilliseconds

when isMainModule:
  main()

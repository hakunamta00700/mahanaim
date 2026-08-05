## Deterministic route matching for the framework core.
##
## The router deliberately keeps the public contract independent of the HTTP
## server.  A route is registered once, then the same metadata can be used by
## dispatch, URL generation, inspection, and future OpenAPI generation.

import std/[algorithm, options, parseutils, strutils, tables, uri]
import ./core

type
  RouteGroup* = object
    ## A group carries shared path and middleware policy without global state.
    prefix*: string
    middleware*: seq[Middleware]

  CompressedStaticEdge = object
    ## A radix edge stores a run of adjacent static segments as one label.
    ## Dynamic segments still use dedicated parameter/wildcard branches.
    label: seq[string]
    child: int

  CompressedRouteTreeNode = object
    staticChildren: seq[CompressedStaticEdge]
    staticLookup: Table[string, int]
    parameterChild: int
    terminalRoutes: seq[int]
    wildcardRoutes: seq[int]

  RouteIndexStats* = object
    ## Diagnostic counters make the optimization observable without exposing
    ## mutable tree internals to applications.
    staticEdgeCount*: int
    longestStaticEdgeSegments*: int

  Router* = object
    ## Routes remain in registration order for deterministic tie breaking.
    ## `routeNames` and the compressed route index are separate indexes so URL
    ## generation and matching do not scan every route blindly.
    routes*: seq[Route]
    webSocketRoutes*: seq[WebSocketRoute]
    routeNames: Table[string, int]
    webSocketNames: Table[string, bool]
    compressedRouteTree: seq[CompressedRouteTreeNode]

proc newCompressedRouteTreeNode(): CompressedRouteTreeNode =
  result.staticChildren = @[]
  result.staticLookup = initTable[string, int]()
  result.parameterChild = -1
  result.terminalRoutes = @[]
  result.wildcardRoutes = @[]

proc initRouter*(): Router =
  result.routes = @[]
  result.webSocketRoutes = @[]
  result.routeNames = initTable[string, int]()
  result.webSocketNames = initTable[string, bool]()
  result.compressedRouteTree = @[newCompressedRouteTreeNode()]

proc newRouteGroup*(prefix: string, middleware: seq[Middleware] = @[]): RouteGroup =
  ## Groups are values, making it safe to define reusable route conventions.
  RouteGroup(prefix: prefix, middleware: middleware)

proc normalizePattern(pattern: string): string =
  ## Keep route matching and URL generation on one canonical path shape.
  if pattern.len == 0 or pattern == "/":
    return "/"
  result = "/" & pattern.strip(chars = {'/'})

proc joinPrefix(prefix, pattern: string): string =
  ## Joining is centralized so nested-looking group paths never create `//`.
  let left = prefix.strip(chars = {'/'})
  let right = pattern.strip(chars = {'/'})
  if left.len == 0 and right.len == 0:
    return "/"
  if left.len == 0:
    return normalizePattern(right)
  if right.len == 0:
    return normalizePattern(left)
  normalizePattern(left & "/" & right)

proc splitPath(value: string): seq[string] =
  ## Normalize a path into non-empty segments for route matching and indexing.
  for segment in value.split('/'):
    if segment.len > 0:
      result.add(segment)

proc staticRunEnd(segments: seq[string], start: int): int =
  ## Return the first dynamic/wildcard boundary for radix insertion.
  result = start
  while result < segments.len and
      segments[result].len > 0 and segments[result][0] notin {':', '*'}:
    inc result

proc commonStaticPrefix(label, segments: seq[string], start, stop: int): int =
  ## Compare an existing compressed edge with the next static route run.
  result = 0
  while result < label.len and start + result < stop and
      label[result] == segments[start + result]:
    inc result

proc indexCompressedRoute(router: var Router, pattern: string,
                          routeIndex: int) =
  ## Insert a route into a compressed static radix tree. Splitting an edge is
  ## the only mutation beyond ordinary trie insertion; it preserves separate
  ## parameter and wildcard branches at the split node.
  let segments = splitPath(pattern)
  var nodeIndex = 0
  var segmentIndex = 0
  while segmentIndex < segments.len:
    let segment = segments[segmentIndex]
    if segment.len > 0 and segment[0] == '*':
      router.compressedRouteTree[nodeIndex].wildcardRoutes.add(routeIndex)
      return
    if segment.len > 0 and segment[0] == ':':
      if router.compressedRouteTree[nodeIndex].parameterChild < 0:
        let childIndex = router.compressedRouteTree.len
        router.compressedRouteTree.add(newCompressedRouteTreeNode())
        router.compressedRouteTree[nodeIndex].parameterChild = childIndex
      nodeIndex = router.compressedRouteTree[nodeIndex].parameterChild
      inc segmentIndex
      continue

    let runEnd = staticRunEnd(segments, segmentIndex)
    var edgeIndex = -1
    if router.compressedRouteTree[nodeIndex].staticLookup.hasKey(segment):
      edgeIndex = router.compressedRouteTree[nodeIndex].staticLookup[segment]
    if edgeIndex < 0:
      let childIndex = router.compressedRouteTree.len
      router.compressedRouteTree.add(newCompressedRouteTreeNode())
      edgeIndex = router.compressedRouteTree[nodeIndex].staticChildren.len
      router.compressedRouteTree[nodeIndex].staticChildren.add(
        CompressedStaticEdge(label: segments[segmentIndex ..< runEnd],
          child: childIndex))
      router.compressedRouteTree[nodeIndex].staticLookup[segment] = edgeIndex
      nodeIndex = childIndex
      segmentIndex = runEnd
      continue

    let edge = router.compressedRouteTree[nodeIndex].staticChildren[edgeIndex]
    let common = commonStaticPrefix(edge.label, segments,
      segmentIndex, runEnd)
    if common < edge.label.len:
      let splitIndex = router.compressedRouteTree.len
      router.compressedRouteTree.add(newCompressedRouteTreeNode())
      router.compressedRouteTree[splitIndex].staticChildren.add(
        CompressedStaticEdge(label: edge.label[common .. ^1],
          child: edge.child))
      router.compressedRouteTree[splitIndex].staticLookup[
        edge.label[common]] = 0
      router.compressedRouteTree[nodeIndex].staticChildren[edgeIndex] =
        CompressedStaticEdge(label: edge.label[0 ..< common],
          child: splitIndex)
      nodeIndex = splitIndex
    else:
      nodeIndex = edge.child
    segmentIndex += common
  router.compressedRouteTree[nodeIndex].terminalRoutes.add(routeIndex)

proc addRoute*(router: var Router, httpMethod, pattern, name: string,
               handler: Handler, middleware: seq[Middleware] = @[],
               executionKind = hekAsync,
               syncHandler: SyncHandler = nil) =
  ## Registration is explicit and rejects duplicate names early.  A duplicate
  ## route name would make generated links depend on registration order.
  let normalizedName = name.strip()
  if normalizedName.len > 0 and router.routeNames.hasKey(normalizedName):
    raise newException(ValueError, "Duplicate route name: " & normalizedName)
  let index = router.routes.len
  router.routes.add(Route(
    httpMethod: httpMethod.toUpperAscii(), pattern: normalizePattern(pattern),
    name: normalizedName, handler: handler, syncHandler: syncHandler,
    middleware: middleware,
    executionKind: executionKind))
  if normalizedName.len > 0:
    router.routeNames[normalizedName] = index
  router.indexCompressedRoute(normalizePattern(pattern), index)

proc addWebSocketRoute*(router: var Router, pattern, name: string,
                        handler: WebSocketHandler) =
  ## Keep upgrade routes out of HTTP method matching while reusing the same
  ## path grammar and registration-time duplicate-name protection.
  let normalizedName = name.strip()
  if normalizedName.len > 0 and
     (router.routeNames.hasKey(normalizedName) or
      router.webSocketNames.hasKey(normalizedName)):
    raise newException(ValueError, "Duplicate route name: " & normalizedName)
  router.webSocketRoutes.add(WebSocketRoute(
    pattern: normalizePattern(pattern), name: normalizedName, handler: handler))
  if normalizedName.len > 0:
    router.webSocketNames[normalizedName] = true

proc addRoute*(router: var Router, group: RouteGroup, httpMethod, pattern,
               name: string, handler: Handler,
               middleware: seq[Middleware] = @[],
               executionKind = hekAsync,
               syncHandler: SyncHandler = nil) =
  ## Group middleware is outermost and local middleware remains closest to the
  ## handler, matching the same onion ordering as global middleware.
  router.addRoute(httpMethod, joinPrefix(group.prefix, pattern), name, handler,
    group.middleware & middleware, executionKind, syncHandler)

type PathParameter = object
  name: string
  kind: string
  wildcard: bool

proc parameterFor(segment: string): Option[PathParameter] =
  ## Parse `:id`, `:id<int>`, and `*path` without exposing parser internals.
  if segment.len < 2 or (segment[0] != ':' and segment[0] != '*'):
    return none(PathParameter)
  let wildcard = segment[0] == '*'
  let raw = segment[1 .. ^1]
  let typeStart = raw.find('<')
  if typeStart < 0:
    if raw.len == 0:
      return none(PathParameter)
    return some(PathParameter(name: raw, kind: "", wildcard: wildcard))
  if not raw.endsWith(">") or typeStart == 0:
    return none(PathParameter)
  let kind = raw[typeStart + 1 ..< raw.len - 1].toLowerAscii()
  if kind.len == 0:
    return none(PathParameter)
  some(PathParameter(name: raw[0 ..< typeStart], kind: kind, wildcard: wildcard))

proc validParameter(value, kind: string): bool =
  ## Typed route constraints fail at routing time, before handler execution.
  if kind.len == 0:
    return true
  case kind
  of "int":
    var parsed: int
    parseInt(value, parsed) == value.len
  of "uint":
    var parsed: uint
    parseUInt(value, parsed) == value.len
  of "float":
    var parsed: float
    parseFloat(value, parsed) == value.len
  of "bool":
    value.toLowerAscii() in ["true", "false"]
  else:
    false

proc matchPattern(pattern, path: string,
                  params: var Table[string, string]): bool =
  ## Match static, typed, named, and trailing wildcard segments.
  let expected = splitPath(pattern)
  let actual = splitPath(path)
  var actualIndex = 0
  for expectedIndex, expectedSegment in expected:
    let parameter = parameterFor(expectedSegment)
    if parameter.isSome and parameter.get().wildcard:
      let wildcard = parameter.get()
      if expectedIndex != expected.high or actualIndex >= actual.len:
        return false
      let value = actual[actualIndex .. ^1].join("/")
      if not validParameter(value, wildcard.kind):
        return false
      params[wildcard.name] = value
      return true
    if actualIndex >= actual.len:
      return false
    if parameter.isSome:
      let parsed = parameter.get()
      if not validParameter(actual[actualIndex], parsed.kind):
        return false
      params[parsed.name] = actual[actualIndex]
    elif expectedSegment != actual[actualIndex]:
      return false
    inc actualIndex
  actualIndex == actual.len

proc routeScore(route: Route): int =
  ## Static segments outrank parameters, which outrank wildcards.  Registration
  ## order remains the tie breaker because `find` only replaces on `>`.
  for segment in splitPath(route.pattern):
    let parameter = parameterFor(segment)
    if parameter.isSome:
      result += (if parameter.get().wildcard: 0 elif parameter.get().kind.len > 0: 20 else: 10)
    else:
      result += 30

proc candidateIndexes(router: Router, path: string): seq[int] =
  ## Walk compressed static edges plus parameter and wildcard branches that
  ## can consume this path. Traversal order is not registration order, so the
  ## final numeric sort explicitly preserves the existing tie-break contract.
  let segments = splitPath(path)
  type TreeState = tuple[nodeIndex: int, pathIndex: int]
  var pending: seq[TreeState] = @[(nodeIndex: 0, pathIndex: 0)]
  while pending.len > 0:
    let state = pending.pop()
    let node = router.compressedRouteTree[state.nodeIndex]
    if state.pathIndex == segments.len:
      result.add(node.terminalRoutes)
      continue
    for routeIndex in node.wildcardRoutes:
      result.add(routeIndex)
    let nextSegment = segments[state.pathIndex]
    if node.staticLookup.hasKey(nextSegment):
      let edge = node.staticChildren[node.staticLookup[nextSegment]]
      if state.pathIndex + edge.label.len <= segments.len:
        var matches = true
        for offset, labelSegment in edge.label:
          if labelSegment != segments[state.pathIndex + offset]:
            matches = false
            break
        if matches:
          pending.add((edge.child, state.pathIndex + edge.label.len))
    if node.parameterChild >= 0:
      pending.add((node.parameterChild, state.pathIndex + 1))
  result.sort(system.cmp[int])

proc routeIndexStats*(router: Router): RouteIndexStats =
  ## Report compression without exposing mutable node storage. This is useful
  ## for benchmark assertions and gives maintainers a stable optimization
  ## signal independent of machine-specific latency.
  for node in router.compressedRouteTree:
    for edge in node.staticChildren:
      inc result.staticEdgeCount
      result.longestStaticEdgeSegments = max(
        result.longestStaticEdgeSegments, edge.label.len)

proc matchingRoute(router: Router, path: string,
                   requestedMethod: Option[string]): Option[Route] =
  var bestScore = -1
  for index in router.candidateIndexes(path):
    let route = router.routes[index]
    if requestedMethod.isSome and
       route.httpMethod != requestedMethod.get().toUpperAscii():
      continue
    var params = initTable[string, string]()
    if matchPattern(route.pattern, path, params):
      let score = routeScore(route)
      if score > bestScore:
        bestScore = score
        result = some(route)

proc find*(router: Router, request: Request): Option[Route] =
  ## Return the best method-matching route without mutating the request.
  matchingRoute(router, request.path, some(request.httpMethod))

proc findPath*(router: Router, path: string): Option[Route] =
  ## Find a route by path regardless of method, used for reliable 405 handling.
  matchingRoute(router, path, none(string))

proc findNamed*(router: Router, name: string): Option[Route] =
  ## Route inspection and URL building share the same name index.
  if router.routeNames.hasKey(name):
    return some(router.routes[router.routeNames[name]])
  none(Route)

proc findWebSocket*(router: Router, path: string): Option[WebSocketRoute] =
  ## Choose the most specific upgrade route with the same scoring policy as
  ## HTTP routes; registration order remains the tie breaker.
  var bestScore = -1
  for route in router.webSocketRoutes:
    var params = initTable[string, string]()
    if matchPattern(route.pattern, path, params):
      let score = routeScore(Route(pattern: route.pattern))
      if score > bestScore:
        bestScore = score
        result = some(route)

proc extractParams*(pattern, path: string): Option[Table[string, string]] =
  ## Public helper for the dispatcher and route-level tests.
  var params = initTable[string, string]()
  if matchPattern(normalizePattern(pattern), path, params):
    return some(params)
  none(Table[string, string])

proc urlFor*(router: Router, name: string,
            params: Table[string, string]): string =
  ## Build a route URL from the same declaration used by dispatch.
  let route = router.findNamed(name)
  if route.isNone:
    raise newException(ValueError, "Unknown route name: " & name)
  var segments: seq[string] = @[]
  for segment in splitPath(route.get().pattern):
    let parameter = parameterFor(segment)
    if parameter.isSome:
      let parsed = parameter.get()
      if not params.hasKey(parsed.name):
        raise newException(ValueError, "Missing route parameter: " & parsed.name)
      let value = params[parsed.name]
      if not validParameter(value, parsed.kind):
        raise newException(ValueError, "Invalid route parameter: " & parsed.name)
      if parsed.wildcard:
        ## Keep wildcard slashes as path separators, but encode each part so
        ## user data cannot introduce query, fragment, or encoded separators.
        let parts = value.split('/')
        var hasEmptyPart = parts.len == 0
        for part in parts:
          if part.len == 0:
            hasEmptyPart = true
            break
        if hasEmptyPart:
          raise newException(ValueError,
            "Wildcard route parameter must contain non-empty path segments: " &
            parsed.name)
        for part in parts:
          segments.add(encodeUrl(part, usePlus = false))
      else:
        ## A named parameter occupies exactly one path segment.  In
        ## particular, '/' and '?' must never alter the generated route shape.
        segments.add(encodeUrl(value, usePlus = false))
    else:
      segments.add(segment)
  if segments.len == 0:
    return "/"
  "/" & segments.join("/")

proc urlFor*(router: Router, name: string): string =
  ## Convenience overload for routes without parameters.
  urlFor(router, name, initTable[string, string]())

## Deterministic route matching for the framework core.
##
## The router deliberately keeps the public contract independent of the HTTP
## server.  A route is registered once, then the same metadata can be used by
## dispatch, URL generation, inspection, and future OpenAPI generation.

import std/[options, parseutils, strutils, tables]
import ./core

type
  RouteGroup* = object
    ## A group carries shared path and middleware policy without global state.
    prefix*: string
    middleware*: seq[Middleware]

  Router* = object
    ## Routes remain in registration order for deterministic tie breaking.
    ## `routeNames` is a separate index so URL generation does not scan blindly.
    routes*: seq[Route]
    routeNames: Table[string, int]

proc initRouter*(): Router =
  result.routes = @[]
  result.routeNames = initTable[string, int]()

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

proc addRoute*(router: var Router, httpMethod, pattern, name: string,
               handler: Handler, middleware: seq[Middleware] = @[]) =
  ## Registration is explicit and rejects duplicate names early.  A duplicate
  ## route name would make generated links depend on registration order.
  let normalizedName = name.strip()
  if normalizedName.len > 0 and router.routeNames.hasKey(normalizedName):
    raise newException(ValueError, "Duplicate route name: " & normalizedName)
  let index = router.routes.len
  router.routes.add(Route(
    httpMethod: httpMethod.toUpperAscii(), pattern: normalizePattern(pattern),
    name: normalizedName, handler: handler, middleware: middleware))
  if normalizedName.len > 0:
    router.routeNames[normalizedName] = index

proc addRoute*(router: var Router, group: RouteGroup, httpMethod, pattern,
               name: string, handler: Handler,
               middleware: seq[Middleware] = @[]) =
  ## Group middleware is outermost and local middleware remains closest to the
  ## handler, matching the same onion ordering as global middleware.
  router.addRoute(httpMethod, joinPrefix(group.prefix, pattern), name, handler,
    group.middleware & middleware)

proc splitPath(value: string): seq[string] =
  ## Normalize a path into non-empty segments for route matching.
  for segment in value.split('/'):
    if segment.len > 0:
      result.add(segment)

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

proc matchingRoute(router: Router, path: string,
                   requestedMethod: Option[string]): Option[Route] =
  var bestScore = -1
  for route in router.routes:
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
        for part in splitPath(value):
          segments.add(part)
      else:
        segments.add(value)
    else:
      segments.add(segment)
  if segments.len == 0:
    return "/"
  "/" & segments.join("/")

proc urlFor*(router: Router, name: string): string =
  ## Convenience overload for routes without parameters.
  urlFor(router, name, initTable[string, string]())

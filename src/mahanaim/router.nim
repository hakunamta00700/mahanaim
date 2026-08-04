## Deterministic route matching for the framework core.

import std/[options, strutils, tables]
import ./core

type
  Router* = object
    ## Routes remain in registration order, making precedence explicit.
    routes*: seq[Route]

proc initRouter*(): Router =
  result.routes = @[]

proc addRoute*(router: var Router, httpMethod, pattern, name: string,
               handler: Handler, middleware: seq[Middleware] = @[]) =
  ## Registration is deliberately explicit; no hidden global route state exists.
  router.routes.add(Route(
    httpMethod: httpMethod.toUpperAscii(), pattern: pattern, name: name,
    handler: handler, middleware: middleware))

proc splitPath(value: string): seq[string] =
  ## Normalize a path into non-empty segments for exact and parameter routes.
  for segment in value.split('/'):
    if segment.len > 0:
      result.add(segment)

proc matchPattern(pattern, path: string, params: var Table[string, string]): bool =
  ## Supports static segments and `:typedName` parameters in the first slice.
  let expected = splitPath(pattern)
  let actual = splitPath(path)
  if expected.len != actual.len:
    return false

  for index in 0 ..< expected.len:
    let expectedSegment = expected[index]
    let actualSegment = actual[index]
    if expectedSegment.startsWith(":"):
      let key = expectedSegment[1 .. ^1]
      if key.len == 0:
        return false
      params[key] = actualSegment
    elif expectedSegment != actualSegment:
      return false
  true

proc find*(router: Router, request: Request): Option[Route] =
  ## Return the first matching route and copy extracted path parameters.
  for route in router.routes:
    if route.httpMethod != request.httpMethod.toUpperAscii():
      continue
    var params = initTable[string, string]()
    if matchPattern(route.pattern, request.path, params):
      var matched = route
      matched.handler = route.handler
      matched.middleware = route.middleware
      # The request receives params in Application.dispatch; this copy keeps
      # Router.find side-effect free and therefore safe to use for inspection.
      return some(matched)
  none(Route)

proc extractParams*(pattern, path: string): Option[Table[string, string]] =
  ## Public helper for the dispatcher and route-level tests.
  var params = initTable[string, string]()
  if matchPattern(pattern, path, params):
    return some(params)
  none(Table[string, string])

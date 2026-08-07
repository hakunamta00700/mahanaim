## Declarative HTTP route registration.
##
## The DSL expands to the ordinary Application registration API, so routing,
## middleware ordering, lifecycle checks, and URL generation keep one runtime
## implementation. Its only job is to remove repetitive handler closures while
## keeping adapters and mounted route bundles explicit at the declaration site.

import std/[asyncdispatch, macros, sets, strutils]
import ./application
import ./core

type RouteDslState = object
  namePrefix: string
  pathPrefix: string
  adapter: NimNode
  names: HashSet[string]
  signatures: HashSet[string]

proc trustedSyncHandler(
    handler: proc(request: Request): Response): SyncHandler =
  ## The DSL caller opts into sync execution; receiver-style closures need the
  ## same explicit GC-safety boundary as a direct getSync/postSync call.
  cast[SyncHandler](handler)

proc normalizedPart(value: string, separator: char): string {.compileTime.} =
  value.strip(chars = {separator})

proc joinedPath(prefix, path: string): string {.compileTime.} =
  let left = normalizedPart(prefix, '/')
  let right = normalizedPart(path, '/')
  if left.len == 0 and right.len == 0:
    return "/"
  if left.len == 0:
    return "/" & right
  if right.len == 0:
    return "/" & left
  "/" & left & "/" & right

proc qualifiedName(prefix, name: string): string {.compileTime.} =
  let left = normalizedPart(prefix, '.')
  let right = normalizedPart(name, '.')
  if left.len == 0:
    return right
  if right.len == 0:
    return left
  left & "." & right

proc stringLiteral(node: NimNode, description: string): string
    {.compileTime.} =
  if node.kind notin {nnkStrLit .. nnkTripleStrLit}:
    error(description & " must be a string literal", node)
  node.strVal

proc appendStatements(target: NimNode, source: NimNode) {.compileTime.} =
  if source.kind == nnkStmtList:
    for statement in source:
      target.add(statement)
  else:
    target.add(source)

proc handlerClosure(target: NimNode, adapter: NimNode): NimNode
    {.compileTime.} =
  let request = genSym(nskParam, "request")
  let invocation = newCall(target.copyNimTree(), request)
  if adapter.isNil:
    result = quote do:
      (proc(`request`: Request): Future[Response] {.async, gcsafe.} =
        return await `invocation`)
  else:
    let viewHandler = quote do:
      (proc(`request`: Request): Future[Response] {.async.} =
        return await `invocation`)
    result = newCall(adapter.copyNimTree(), viewHandler)

proc syncHandlerClosure(target: NimNode): NimNode {.compileTime.} =
  ## Sync routes need an explicit cast because the captured receiver can carry
  ## state whose GC-safety the macro cannot prove on its own.
  let request = genSym(nskParam, "request")
  result = quote do:
    trustedSyncHandler(
      proc(`request`: Request): Response =
        `target`(`request`)
    )

proc webSocketHandlerClosure(target: NimNode): NimNode {.compileTime.} =
  let request = genSym(nskParam, "request")
  let session = genSym(nskParam, "session")
  result = quote do:
    proc(`request`: Request,
         `session`: WebSocketSession): Future[void] {.gcsafe.} =
      `target`(`request`, `session`)

proc expandRoute(app, declaration: NimNode, httpMethod: string,
                 state: var RouteDslState): NimNode {.compileTime.} =
  if declaration.len != 4:
    error(httpMethod.toLowerAscii() &
      " requires path, name, and handler", declaration)
  let path = joinedPath(state.pathPrefix,
    stringLiteral(declaration[1], "Route path"))
  let name = qualifiedName(state.namePrefix,
    stringLiteral(declaration[2], "Route name"))
  if name.len == 0:
    error("Route name must not be empty", declaration[2])
  if name in state.names:
    error("Duplicate route name in routes block: " & name, declaration[2])
  state.names.incl(name)
  let signature = httpMethod.toUpperAscii() & " " & path
  if signature in state.signatures:
    error("Duplicate route declaration in routes block: " & signature,
      declaration)
  state.signatures.incl(signature)

  let handler = handlerClosure(declaration[3], state.adapter)
  case httpMethod.toUpperAscii()
  of "GET":
    result = newCall(newDotExpr(app.copyNimTree(), ident("get")),
      newLit(path), newLit(name), handler)
  of "POST":
    result = newCall(newDotExpr(app.copyNimTree(), ident("post")),
      newLit(path), newLit(name), handler)
  else:
    result = newCall(newDotExpr(app.copyNimTree(), ident("addRoute")),
      newLit(httpMethod.toUpperAscii()), newLit(path), newLit(name), handler)

proc expandSyncRoute(app, declaration: NimNode, routeKind: string,
                     state: var RouteDslState): NimNode {.compileTime.} =
  if declaration.len != 4:
    error(routeKind & " requires path, name, and handler", declaration)
  let path = joinedPath(state.pathPrefix,
    stringLiteral(declaration[1], "Route path"))
  let name = qualifiedName(state.namePrefix,
    stringLiteral(declaration[2], "Route name"))
  if name.len == 0:
    error("Route name must not be empty", declaration[2])
  if name in state.names:
    error("Duplicate route name in routes block: " & name, declaration[2])
  state.names.incl(name)
  let signature = routeKind.toUpperAscii() & " " & path
  if signature in state.signatures:
    error("Duplicate route declaration in routes block: " & signature,
      declaration)
  state.signatures.incl(signature)
  let handler = syncHandlerClosure(declaration[3])
  let registration = case routeKind
    of "getSync": bindSym"getSync"
    of "postSync": bindSym"postSync"
    of "putSync": bindSym"putSync"
    of "patchSync": bindSym"patchSync"
    of "deleteSync": bindSym"deleteSync"
    else: error("Unsupported synchronous route kind: " & routeKind, declaration)
  result = newCall(registration, app.copyNimTree(),
    newLit(path), newLit(name), handler)

proc expandWebSocketRoute(app, declaration: NimNode,
                          state: var RouteDslState): NimNode {.compileTime.} =
  if declaration.len != 4:
    error("websocket requires path, name, and handler", declaration)
  let path = joinedPath(state.pathPrefix,
    stringLiteral(declaration[1], "Route path"))
  let name = qualifiedName(state.namePrefix,
    stringLiteral(declaration[2], "Route name"))
  if name.len == 0:
    error("Route name must not be empty", declaration[2])
  if name in state.names:
    error("Duplicate route name in routes block: " & name, declaration[2])
  state.names.incl(name)
  let signature = "WEBSOCKET " & path
  if signature in state.signatures:
    error("Duplicate route declaration in routes block: " & signature,
      declaration)
  state.signatures.incl(signature)
  let handler = webSocketHandlerClosure(declaration[3])
  result = newCall(bindSym"websocket", app.copyNimTree(),
    newLit(path), newLit(name), handler)

proc expandStatements(app, statements: NimNode,
                      state: var RouteDslState): NimNode {.compileTime.} =
  result = newStmtList()
  let body = if statements.kind == nnkStmtList: statements
             else: newStmtList(statements)
  for statement in body:
    if statement.kind notin {nnkCall, nnkCommand} or statement.len == 0:
      error("Unsupported statement in routes block", statement)

    let routeKind = $statement[0]
    case routeKind
    of "get":
      result.add(expandRoute(app, statement, "GET", state))
    of "post":
      result.add(expandRoute(app, statement, "POST", state))
    of "getSync":
      result.add(expandSyncRoute(app, statement, "getSync", state))
    of "postSync":
      result.add(expandSyncRoute(app, statement, "postSync", state))
    of "putSync":
      result.add(expandSyncRoute(app, statement, "putSync", state))
    of "patchSync":
      result.add(expandSyncRoute(app, statement, "patchSync", state))
    of "deleteSync":
      result.add(expandSyncRoute(app, statement, "deleteSync", state))
    of "websocket":
      result.add(expandWebSocketRoute(app, statement, state))
    of "route":
      if statement.len != 5:
        error("route requires method, path, name, and handler", statement)
      let httpMethod = stringLiteral(statement[1], "HTTP method")
      var normalized = newCall(ident("route"), statement[2], statement[3],
        statement[4])
      result.add(expandRoute(app, normalized, httpMethod, state))
    of "middleware":
      if statement.len != 2:
        error("middleware requires exactly one handler", statement)
      result.add(newCall(newDotExpr(app.copyNimTree(), ident("addMiddleware")),
        statement[1]))
    of "mount":
      if statement.len != 2:
        error("mount requires exactly one registration expression", statement)
      result.add(statement[1])
    of "group":
      if statement.len != 3:
        error("group requires a path prefix and a body", statement)
      let savedPrefix = state.pathPrefix
      state.pathPrefix = joinedPath(savedPrefix,
        stringLiteral(statement[1], "Group path"))
      appendStatements(result, expandStatements(app, statement[2], state))
      state.pathPrefix = savedPrefix
    of "adapt":
      if statement.len != 3:
        error("adapt requires an adapter and a body", statement)
      let savedAdapter = state.adapter
      state.adapter = statement[1]
      appendStatements(result, expandStatements(app, statement[2], state))
      state.adapter = savedAdapter
    else:
      error("Unknown routes declaration: " & routeKind, statement)

proc expandRoutes(app: NimNode, namePrefix: string,
                  body: NimNode): NimNode {.compileTime.} =
  var state = RouteDslState(
    namePrefix: namePrefix,
    names: initHashSet[string](),
    signatures: initHashSet[string]())
  expandStatements(app, body, state)

macro routes*(app: typed, body: untyped): untyped =
  ## Declare routes without a route-name prefix.
  expandRoutes(app, "", body)

macro routes*(app: typed, namePrefix: static[string],
              body: untyped): untyped =
  ## Declare routes whose local names share one stable dotted prefix.
  expandRoutes(app, namePrefix, body)

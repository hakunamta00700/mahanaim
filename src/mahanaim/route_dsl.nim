## Concise route declarations for application modules.
##
## The DSL keeps transport behavior explicit (`getSync` versus `get`) while
## generating the small adapter closures required for receiver-style handlers.

import std/[asyncdispatch, macros]

import ./application
import ./core

proc trustedSyncHandler(
    handler: proc(request: Request): Response): SyncHandler =
  ## Receiver-style closures inherit the GC-safety of captured state. A sync
  ## declaration is the caller's explicit assertion that the receiver already
  ## serializes that state, matching a manual cast before `getSync`/`postSync`.
  cast[SyncHandler](handler)

proc declarationName(declaration: NimNode): string =
  let callee = declaration[0]
  if callee.kind notin {nnkIdent, nnkSym}:
    error("route declarations must start with a route kind", callee)
  callee.strVal

macro routes*(app: typed, declarations: untyped): untyped =
  ## Register a block of routes using compact callable declarations:
  ##
  ##   routes app:
  ##     getSync "/", "home", handlers.index
  ##     post "/events", "events.create", handlers.create
  ##     websocket "/ws", "events.socket", service.handleSocket
  ##
  ## Supported kinds mirror Application's public registration API. The final
  ## argument is a callable receiving Request, or Request and WebSocketSession.
  let body = if declarations.kind == nnkStmtList:
    declarations
  else:
    newStmtList(declarations)

  result = newStmtList()
  for declaration in body:
    if declaration.kind notin {nnkCall, nnkCommand}:
      error("expected a route declaration", declaration)
    if declaration.len != 4:
      error("route declarations require path, name, and handler", declaration)

    let kind = declaration.declarationName()
    let path = declaration[1]
    let name = declaration[2]
    let handler = declaration[3]
    let request = genSym(nskParam, "request")

    case kind
    of "getSync", "postSync", "putSync", "patchSync", "deleteSync":
      let registration = case kind
        of "getSync": bindSym"getSync"
        of "postSync": bindSym"postSync"
        of "putSync": bindSym"putSync"
        of "patchSync": bindSym"patchSync"
        else: bindSym"deleteSync"
      let adapter = quote do:
        trustedSyncHandler(
          proc(`request`: Request): Response =
            `handler`(`request`)
        )
      result.add newCall(registration, app, path, name, adapter)
    of "get", "post":
      let registration = if kind == "get": bindSym"get"
                         else: bindSym"post"
      let adapter = quote do:
        proc(`request`: Request): Future[Response] {.gcsafe.} =
          `handler`(`request`)
      result.add newCall(registration, app, path, name, adapter)
    of "websocket":
      let session = genSym(nskParam, "session")
      let adapter = quote do:
        proc(`request`: Request,
             `session`: WebSocketSession): Future[void] {.gcsafe.} =
          `handler`(`request`, `session`)
      result.add newCall(bindSym"websocket", app, path, name, adapter)
    else:
      error("unsupported route kind '" & kind &
        "'; expected get, post, getSync, postSync, putSync, patchSync, " &
        "deleteSync, or websocket", declaration[0])

## Minimal public API example.
##
## This file is intentionally executable: documentation examples must use the
## same Application, route, and dispatch contracts as a real application.

import std/[asyncdispatch, httpcore, json, strutils]
import mahanaim

proc main() =
  let app = newApplication()
  app.get("/", "home",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      discard request
      return htmlResponse("<h1>Hello from Mahanaim</h1>"))
  app.get("/health", "health",
    proc(request: Request): Future[Response] {.async, gcsafe.} =
      discard request
      return jsonResponse(%*{"status": "ok"}))

  ## Startup freezes extension registration and makes the example exercise the
  ## same lifecycle boundary as a deployed application.
  app.startup()
  try:
    let home = waitFor app.dispatch(newRequest("GET", "/"))
    let health = waitFor app.dispatch(newRequest("GET", "/health"))
    doAssert home.status == Http200
    doAssert home.body.contains("Hello from Mahanaim")
    doAssert health.status == Http200
    doAssert parseJson(health.body)["status"].getStr() == "ok"
    echo "minimal-app-ok"
  finally:
    app.shutdown()

when isMainModule:
  main()

## Executable plugin route, service, dependency, and duplicate example.

import std/[asyncdispatch, httpcore]
import mahanaim

type GreetingService = ref object of DependencyService

proc newGreetingService(): DependencyService {.gcsafe.} =
  GreetingService()

proc greeting(request: Request): Future[Response] {.async, gcsafe.} =
  doAssert not request.services.resolve("example.greeting").isNil
  return textResponse("hello from plugin", Http200)

proc installGreetingPlugin(app: Application) {.gcsafe.} =
  app.provide("example.greeting", dependencyApplication, newGreetingService)
  app.get("/plugin-greeting", "plugin.greeting", greeting)

let manifest = PluginManifest(name: "example-greeting", version: "1.0.0",
  phase: pluginServices, dependencies: @[])
let plugin = newPlugin(manifest, installGreetingPlugin)
let app = newApplication()
app.use(plugin)

let response = waitFor app.dispatch(newRequest("GET", "/plugin-greeting"))
doAssert response.status == Http200
doAssert response.body == "hello from plugin"

var duplicateRejected = false
try:
  app.use(plugin)
except ValueError:
  duplicateRejected = true
doAssert duplicateRejected

var dependencyRejected = false
try:
  discard resolvePluginManifests([PluginManifest(name: "dependent", version: "1.0.0",
    phase: pluginRoutes, dependencies: @["missing"])])
except ValueError:
  dependencyRejected = true
doAssert dependencyRejected
echo "plugin-extension-ok"

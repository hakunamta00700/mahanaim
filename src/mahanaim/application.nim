## Application lifecycle and middleware dispatcher.

import std/[asyncdispatch, httpcore, options, strutils, tables]
import ./core
import ./database_pool
import ./router
import ./config
import ./security
import ./models
import ./execution
import ./observability
import ./di
import ./jobs
import ./migration_commands

type
  LifecycleHook* = proc ()

  PluginRegistrationPhase* = enum
    ## Phases make plugin ordering explicit without forcing a DI framework.
    pluginMiddleware
    pluginRoutes
    pluginServices
    pluginMetadata
    pluginSerialization
    pluginStorage
    pluginAuth
    pluginCommands
    pluginAdmin

  PluginManifest* = object
    ## Versioned metadata is inspectable before plugin installation.
    name*: string
    version*: string
    phase*: PluginRegistrationPhase
    dependencies*: seq[string]

  PluginInstaller* = proc (app: Application) {.gcsafe.}

  CommandHandler* = proc (arguments: seq[string]): int {.gcsafe.}

  CommandDefinition* = object
    ## CLI commands are data so different frontends can discover and invoke
    ## the same application-owned operation.
    name*: string
    description*: string
    handler*: CommandHandler

  AdminExtensionInstaller* = proc (app: Application) {.gcsafe.}

  AdminExtension* = object
    ## Admin extensions register framework routes/policies through an explicit
    ## installer; authorization and persistence remain separate concerns.
    name*: string
    install*: AdminExtensionInstaller

  PluginDefinition* = ref object
    manifest*: PluginManifest
    install*: PluginInstaller

  Application* = ref object
    ## Owns routing and lifecycle state for one application instance.
    config*: AppConfig
    router*: Router
    middlewares*: seq[Middleware]
    startupHooks*: seq[LifecycleHook]
    shutdownHooks*: seq[LifecycleHook]
    errorHandler*: ErrorHandler
    plugins*: seq[Plugin]
    pluginManifests*: seq[PluginManifest]
    commands*: Table[string, CommandDefinition]
    adminExtensions*: seq[AdminExtension]
    models*: ModelRegistry
    executionPolicy*: ExecutionPolicy
    executor*: ThreadPoolExecutor
    observability*: Observability
    services*: ServiceContainer
    jobs*: BackgroundJobQueue
    databasePool*: DatabaseConnectionPool
    migrationRegistry*: MigrationRegistry
    migrationDatabasePath*: string
    started*: bool

  ErrorHandler* = proc (request: Request,
                        error: ref CatchableError): Future[Response] {.gcsafe.}
  Plugin* = proc (app: Application)

proc defaultErrorHandler(request: Request,
                         error: ref CatchableError): Future[Response] {.async, gcsafe.}

proc newApplication*(config = defaultConfig(),
                     securityPolicy = defaultSecurityPolicy(),
                     executionPolicy = defaultExecutionPolicy()): Application =
  ## Construct an isolated app instance; this is important for test isolation.
  new(result)
  result.config = config
  result.router = initRouter()
  # Security middleware is installed first so every route and fallback response
  # receives the same defaults before user middleware runs.
  result.middlewares = @[securityMiddleware(securityPolicy)]
  result.startupHooks = @[]
  result.shutdownHooks = @[]
  result.errorHandler = defaultErrorHandler
  result.plugins = @[]
  result.pluginManifests = @[]
  result.commands = initTable[string, CommandDefinition]()
  result.adminExtensions = @[]
  result.models = initModelRegistry()
  result.executionPolicy = executionPolicy
  result.executor = newThreadPoolExecutor(
    maxConcurrentJobs = config.executorMaxConcurrentJobs,
    blockingDetectionMs = executionPolicy.blockingDetectionMs,
    forceCancellationAfterMs = executionPolicy.forceCancellationAfterMs,
    queueWaitMs = executionPolicy.queueWaitMs)
  result.observability = newObservability()
  result.services = newServiceContainer()
  result.jobs = newBackgroundJobQueue(result.executor)
  result.migrationRegistry = newMigrationRegistry()
  result.migrationDatabasePath = ".mahanaim.sqlite"
  result.middlewares.add(observabilityMiddleware(result.observability))
  result.started = false

proc defaultErrorHandler(request: Request,
                         error: ref CatchableError): Future[Response] {.async, gcsafe.} =
  ## Never expose exception text by default; custom handlers can log it safely
  ## after passing through the application's secret redaction policy.
  discard request
  if error of FrameworkError:
    let frameworkError = cast[ref FrameworkError](error)
    return textResponse(frameworkError.msg, frameworkError.status)
  return textResponse("Internal Server Error", Http500)

proc addMiddleware*(app: Application, middleware: Middleware) =
  ## Global middleware runs in registration order around the route handler.
  app.middlewares.add(middleware)

proc configureDatabasePool*(app: Application,
                            pool: DatabaseConnectionPool) =
  ## Inject the pool before startup. The application then owns request-scoped
  ## borrowing and closes idle/active connections during shutdown.
  if app.isNil or pool.isNil:
    raise newException(ValueError, "Application and database pool are required")
  if app.started:
    raise newException(ValueError,
      "Database pool must be configured before application startup")
  app.databasePool = pool

proc configureMigrations*(app: Application, registry: MigrationRegistry,
                          sqlitePath = ".mahanaim.sqlite") =
  ## Migration definitions and the database path are explicit application
  ## inputs; the CLI never scans source files or guesses project modules.
  if app.isNil or registry.isNil or sqlitePath.strip().len == 0:
    raise newException(ValueError,
      "Application, migration registry, and SQLite path are required")
  if app.started:
    raise newException(ValueError,
      "Migrations must be configured before application startup")
  app.migrationRegistry = registry
  app.migrationDatabasePath = sqlitePath

proc registerCommand*(app: Application, command: CommandDefinition) =
  ## Registration is fail-fast so duplicate CLI names cannot shadow commands.
  if command.name.strip().len == 0 or command.handler.isNil:
    raise newException(ValueError, "Command requires a name and handler")
  if app.commands.hasKey(command.name):
    raise newException(ValueError, "Duplicate command: " & command.name)
  app.commands[command.name] = command

proc runCommand*(app: Application, name: string,
                 arguments: openArray[string]): int =
  ## Copy borrowed arguments before crossing the command handler boundary.
  if app.isNil or not app.commands.hasKey(name):
    raise newException(ValueError, "Unknown command: " & name)
  var copied: seq[string] = @[]
  for argument in arguments:
    copied.add(argument)
  app.commands[name].handler(copied)

proc registerAdminExtension*(app: Application, extension: AdminExtension) =
  ## Admin installers are retained for explicit startup integration and are
  ## never silently replaced by a later plugin.
  if extension.name.strip().len == 0 or extension.install.isNil:
    raise newException(ValueError, "Admin extension requires a name and installer")
  for existing in app.adminExtensions:
    if existing.name == extension.name:
      raise newException(ValueError, "Duplicate admin extension: " & extension.name)
  app.adminExtensions.add(extension)
  extension.install(app)

proc newPlugin*(manifest: PluginManifest,
                install: PluginInstaller): PluginDefinition =
  ## Keep plugin declaration immutable after construction and fail early on
  ## malformed manifests rather than during application startup.
  if manifest.name.strip().len == 0 or manifest.version.strip().len == 0:
    raise newException(ValueError, "Plugin manifest requires name and version")
  if install.isNil:
    raise newException(ValueError, "Plugin installer cannot be nil")
  PluginDefinition(manifest: manifest, install: install)

proc resolvePluginManifests*(manifests: openArray[PluginManifest]): seq[PluginManifest] =
  ## Resolve dependencies before any installer runs. Kahn's algorithm keeps
  ## the result deterministic by preserving declaration order for equal ranks.
  var byName = initTable[string, PluginManifest]()
  var indegree = initTable[string, int]()
  var dependents = initTable[string, seq[string]]()
  for manifest in manifests:
    if manifest.name in byName:
      raise newException(ValueError, "Duplicate plugin manifest: " & manifest.name)
    byName[manifest.name] = manifest
    indegree[manifest.name] = 0
    dependents[manifest.name] = @[]
  for manifest in manifests:
    var seenDependencies = initTable[string, bool]()
    for dependency in manifest.dependencies:
      if dependency notin byName:
        raise newException(ValueError, "Missing plugin dependency: " & dependency)
      if seenDependencies.hasKey(dependency):
        raise newException(ValueError,
          "Duplicate plugin dependency: " & dependency)
      seenDependencies[dependency] = true
      inc indegree[manifest.name]
      dependents[dependency].add(manifest.name)

  var ready: seq[string] = @[]
  for manifest in manifests:
    if indegree[manifest.name] == 0:
      ready.add(manifest.name)
  var cursor = 0
  while cursor < ready.len:
    let name = ready[cursor]
    inc cursor
    result.add(byName[name])
    for dependent in dependents[name]:
      dec indegree[dependent]
      if indegree[dependent] == 0:
        ready.add(dependent)
  if result.len != manifests.len:
    raise newException(ValueError, "Cyclic plugin dependency graph")

proc addRoute*(app: Application, httpMethod, pattern, name: string,
               handler: Handler, middleware: seq[Middleware] = @[]) =
  ## The generic registration API keeps less common methods available without
  ## multiplying application-specific wrappers for every HTTP verb.
  app.router.addRoute(httpMethod, pattern, name, handler, middleware)

proc get*(app: Application, pattern, name: string, handler: Handler,
          middleware: seq[Middleware] = @[]) =
  app.addRoute("GET", pattern, name, handler, middleware)

proc post*(app: Application, pattern, name: string, handler: Handler,
           middleware: seq[Middleware] = @[]) =
  app.addRoute("POST", pattern, name, handler, middleware)

proc websocket*(app: Application, pattern, name: string,
                handler: WebSocketHandler) =
  ## Register a live protocol endpoint without pretending it is an HTTP body
  ## handler. Concrete adapters perform the handshake and own the session.
  app.router.addWebSocketRoute(pattern, name, handler)

proc group*(app: Application, prefix: string,
            middleware: seq[Middleware] = @[]): RouteGroup =
  ## Return a reusable route declaration scope.  The application remains the
  ## owner of registration, while the group only carries shared policy.
  newRouteGroup(prefix, middleware)

proc addRoute*(app: Application, group: RouteGroup, httpMethod, pattern,
               name: string, handler: Handler,
               middleware: seq[Middleware] = @[]) =
  ## Grouped routes use the same generic method contract as top-level routes.
  app.router.addRoute(group, httpMethod, pattern, name, handler, middleware)

proc get*(app: Application, group: RouteGroup, pattern, name: string,
          handler: Handler, middleware: seq[Middleware] = @[]) =
  app.addRoute(group, "GET", pattern, name, handler, middleware)

proc post*(app: Application, group: RouteGroup, pattern, name: string,
           handler: Handler, middleware: seq[Middleware] = @[]) =
  app.addRoute(group, "POST", pattern, name, handler, middleware)

proc getSync*(app: Application, pattern, name: string, handler: SyncHandler,
              middleware: seq[Middleware] = @[]) =
  ## Register a synchronous handler explicitly so blocking work is visible in
  ## code review and is routed through the application's executor policy.
  app.router.addRoute("GET", pattern, name, asyncHandler(handler), middleware,
    hekSync, handler)

proc postSync*(app: Application, pattern, name: string, handler: SyncHandler,
               middleware: seq[Middleware] = @[]) =
  ## POST counterpart to getSync; both use the same adapter contract.
  app.router.addRoute("POST", pattern, name, asyncHandler(handler), middleware,
    hekSync, handler)

proc onStartup*(app: Application, hook: LifecycleHook) =
  app.startupHooks.add(hook)

proc onShutdown*(app: Application, hook: LifecycleHook) =
  app.shutdownHooks.add(hook)

proc onError*(app: Application, handler: ErrorHandler) =
  ## Install an explicit application-level exception policy.
  app.errorHandler = handler

proc use*(app: Application, plugin: Plugin) =
  ## Plugins are installed before startup and can register routes, middleware,
  ## commands, or future extension points through the Application contract.
  app.plugins.add(plugin)
  plugin(app)

proc use*(app: Application, plugin: PluginDefinition) =
  ## Manifest plugins are recorded before install so checks and tooling can
  ## inspect registration intent without executing arbitrary plugin code.
  if plugin.isNil:
    raise newException(ValueError, "Plugin definition cannot be nil")
  var candidates = app.pluginManifests
  candidates.add(plugin.manifest)
  discard resolvePluginManifests(candidates)
  app.pluginManifests.add(plugin.manifest)
  app.plugins.add(plugin.install)
  plugin.install(app)

proc registerModel*(app: Application, metadata: ModelMetadata) =
  ## Model registration follows the same isolated application ownership model
  ## as routes and plugins, which keeps test applications deterministic.
  app.models.registerModel(metadata)

proc provide*(app: Application, name: string, scope: DependencyScope,
              provider: DependencyProvider) =
  ## Plugin-facing wrapper keeps service registration on the application owner.
  app.services.provide(name, scope, provider)

proc resolve*(app: Application, name: string): DependencyService =
  ## Resolution remains explicit so request/task lifecycle owners can decide
  ## when to create and release narrower-scope values.
  app.services.resolve(name)

proc wrapMiddleware(current: Middleware, next: Handler): Handler =
  ## A factory gives each closure its own immutable current/next bindings.
  ## Building closures directly inside a loop can otherwise make every layer
  ## point at the final loop binding and recurse into itself.
  result = proc(request: Request): Future[Response] {.gcsafe.} =
    current(request, next)

proc compose(middlewares: seq[Middleware], endpoint: Handler): Handler =
  ## Compose middleware from right to left, making each layer responsible for
  ## exactly one concern and preserving onion-style request/response flow.
  result = endpoint
  for index in countdown(middlewares.high, 0):
    result = wrapMiddleware(middlewares[index], result)

proc notFoundHandler(request: Request): Future[Response] {.async, gcsafe.} =
  ## Keep 404 behavior explicit and replaceable in a later error-handler API.
  discard request
  return textResponse("Not Found", Http404)

proc methodNotAllowedHandler(request: Request): Future[Response] {.async, gcsafe.} =
  discard request
  return textResponse("Method Not Allowed", Http405)

proc synchronousHandlerDisabled(request: Request): Future[Response] {.async, gcsafe.} =
  ## A policy rejection is explicit so a deployment never silently blocks the
  ## event loop by executing an unapproved synchronous handler.
  discard request
  return textResponse("Synchronous handlers are disabled", Http500)

proc invoke(app: Application, request: Request, handler: Handler): Future[Response] {.async.} =
  ## One guarded invocation path prevents sync, async, and plugin routes from
  ## drifting into different exception behavior.
  try:
    let pending = handler(request)
    if app.config.requestTimeoutMs <= 0:
      return await pending

    # `withTimeout` races the handler against a timer. Nim does not provide a
    # safe way to preempt a running async procedure, so the token is cancelled
    # cooperatively and the client receives a deterministic 504 immediately.
    if not await pending.withTimeout(app.config.requestTimeoutMs):
      request.cancellation.cancel()
      let timeoutError = newException(FrameworkError, "Request timed out")
      timeoutError.status = Http504
      timeoutError.code = "request_timeout"
      return await app.errorHandler(request, timeoutError)
    return await pending
  except CatchableError as error:
    return await app.errorHandler(request, error)

proc syncEndpoint(app: Application, handler: SyncHandler): Handler =
  ## Adapt sync work only after middleware has built the final request shape.
  ## The executor boundary therefore includes path parameters and middleware
  ## context while keeping the event loop free for other requests.
  result = proc(request: Request): Future[Response] {.gcsafe.} =
    if app.executionPolicy.offloadSynchronousHandlers and app.executor != nil:
      return app.executor.execute(proc(): Response {.gcsafe.} =
        ## A queued task can outlive its request deadline.  Nim cannot safely
        ## preempt a running worker, so avoid entering user code when the
        ## cooperative token was already cancelled before worker start.
        if request.isCancelled():
          return textResponse("Request cancelled", Http408)
        handler(request), request.cancellation)
    if request.isCancelled():
      return asyncHandler(proc(_: Request): Response {.gcsafe.} =
        textResponse("Request cancelled", Http408))(request)
    asyncHandler(handler)(request)

proc fallback(app: Application, request: Request,
              handler: Handler): Future[Response] {.async.} =
  ## Apply global middleware to 404/405 responses as well as matched routes.
  return await app.invoke(request, compose(app.middlewares, handler))

proc dispatchInternal(app: Application, request: Request): Future[Response] {.async.} =
  ## Dispatch an in-process request after request-scoped resources are attached.
  let matchedRoute = app.router.find(request)
  if matchedRoute.isNone:
    # A path match with another method is a 405, while no path match is a 404.
    if app.router.findPath(request.path).isSome:
      return await app.fallback(request, methodNotAllowedHandler)
    return await app.fallback(request, notFoundHandler)

  let route = matchedRoute.get()
  let params = extractParams(route.pattern, request.path)
  var requestWithParams = request
  if params.isSome:
    requestWithParams.pathParams = params.get()
  if route.executionKind == hekSync and
     not app.executionPolicy.allowSynchronousHandlers:
    return await app.fallback(requestWithParams, synchronousHandlerDisabled)
  var layers = app.middlewares
  layers.add(route.middleware)
  var endpoint = route.handler
  if route.executionKind == hekSync and route.syncHandler != nil:
    endpoint = app.syncEndpoint(route.syncHandler)
  return await app.invoke(requestWithParams, compose(layers, endpoint))

proc dispatch*(app: Application, request: Request): Future[Response] {.async.} =
  ## Network adapters delegate here. A borrowed connection is released on every
  ## route, 404, 405, timeout, and exception path through the finally block.
  if app.databasePool.isNil:
    return await app.dispatchInternal(request)
  let database = app.databasePool.acquire()
  var requestWithDatabase = request
  requestWithDatabase.database = database
  try:
    return await app.dispatchInternal(requestWithDatabase)
  finally:
    app.databasePool.release(database)

proc startup*(app: Application) =
  ## Hooks execute once and in registration order.
  if app.started:
    return
  for hook in app.startupHooks:
    hook()
  app.observability.setReady(true)
  app.started = true

proc shutdown*(app: Application) =
  ## Shutdown is idempotent so signal handlers can safely call it repeatedly.
  if not app.started:
    return
  for index in countdown(app.shutdownHooks.high, 0):
    app.shutdownHooks[index]()
  app.observability.setReady(false)
  if app.databasePool != nil:
    app.databasePool.close()
  app.started = false

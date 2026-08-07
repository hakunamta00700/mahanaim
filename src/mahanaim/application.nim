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
import ./seed_commands
import ./durable_jobs
import ./response_policy
import ./serialization
import ./storage
import ./flash
import ./template_adapters
import ./templates

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

  ModuleInstaller* = proc (app: Application) {.gcsafe.}

  ModuleProvider* = object
    ## Modules keep provider declarations as values until their complete graph
    ## is validated. This prevents half-installed modules after a duplicate or
    ## cycle error and gives composition an explicit override marker.
    registration*: DependencyRegistration
    overrideExisting*: bool

  ApplicationModule* = ref object
    ## A module is an explicit application composition unit. It is intentionally
    ## not discovered from imports or globals: the root application supplies
    ## the module(s) it wants to install.
    name*: string
    imports*: seq[ApplicationModule]
    providers*: seq[ModuleProvider]
    controllers*: seq[ModuleInstaller]
    routes*: seq[ModuleInstaller]
    startupHooks*: seq[LifecycleHook]
    shutdownHooks*: seq[LifecycleHook]
    exports*: seq[string]

  CommandHandler* = proc (arguments: seq[string]): int {.gcsafe.}

  AdminUserCreator* = proc (identifier, password, subject: string): string
    {.gcsafe.}

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
    ## Keep the exact policy used by security middleware so pre-flight checks
    ## inspect the same runtime contract instead of silently falling back to a
    ## different default policy.
    securityPolicy*: SecurityPolicy
    router*: Router
    middlewares*: seq[Middleware]
    startupHooks*: seq[LifecycleHook]
    shutdownHooks*: seq[LifecycleHook]
    errorHandler*: ErrorHandler
    plugins*: seq[Plugin]
    pluginManifests*: seq[PluginManifest]
    commands*: Table[string, CommandDefinition]
    ## User provisioning is an application-owned boundary. The CLI only
    ## validates arguments and obtains the secret; it never knows whether the
    ## application uses SQLite, PostgreSQL, an external identity provider, or
    ## a test double.
    adminUserCreator*: AdminUserCreator
    adminExtensions*: seq[AdminExtension]
    models*: ModelRegistry
    executionPolicy*: ExecutionPolicy
    executor*: ThreadPoolExecutor
    observability*: Observability
    services*: ServiceContainer
    moduleNames: Table[string, bool]
    jobs*: BackgroundJobQueue
    databasePool*: DatabaseConnectionPool
    migrationRegistry*: MigrationRegistry
    migrationDatabasePath*: string
    migrationDatabaseProvider*: MigrationDatabaseProvider
    seedRegistry*: SeedRegistry
    durableJobStore*: DurableJobStore
    durableJobRegistry*: DurableJobRegistry
    ## Plugin-owned codecs and stores live on the application instance so
    ## tests and embedded hosts never share mutable global extension state.
    serializationRegistry*: SerializationAdapterRegistry
    storageAdapters*: Table[string, ObjectStorage]
    flashStore*: FlashStore
    ## The application stores only the adapter contract. Template source,
    ## parser caches, and provider-specific lifecycle remain outside this
    ## dispatcher so an alternate engine does not alter routing or security.
    templateAdapter*: TemplateAdapter
    started*: bool
    ## A separate flag closes the registration window while startup hooks run.
    ## `started` remains false until readiness is published, but extension
    ## registration must already be immutable during that transition.
    starting: bool

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
  result.securityPolicy = securityPolicy
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
    maxQueuedJobs = config.executorMaxQueuedJobs,
    blockingDetectionMs = executionPolicy.blockingDetectionMs,
    forceCancellationAfterMs = executionPolicy.forceCancellationAfterMs,
    queueWaitMs = executionPolicy.queueWaitMs)
  ## Copy configured secret values into the observability boundary once. The
  ## logger then sanitizes every structured record without depending on the
  ## mutable configuration provider or exposing configuration internals.
  var redactedSecrets: seq[string] = @[]
  for _, secret in config.secrets:
    if secret.len > 0 and secret notin redactedSecrets:
      redactedSecrets.add(secret)
  result.observability = newObservability(redactedSecrets = redactedSecrets)
  result.services = newServiceContainer()
  result.moduleNames = initTable[string, bool]()
  result.jobs = newBackgroundJobQueue(result.executor)
  result.migrationRegistry = newMigrationRegistry()
  result.migrationDatabasePath = ".mahanaim.sqlite"
  result.seedRegistry = newSeedRegistry()
  result.serializationRegistry = newSerializationAdapterRegistry()
  result.storageAdapters = initTable[string, ObjectStorage]()
  result.flashStore = newInMemoryFlashStore()
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

proc ensureRegistrationWindow(app: Application, resource: string) =
  ## Request-surface declarations are immutable once startup begins. Keeping
  ## this check in one private helper prevents route and middleware wrappers
  ## from accidentally diverging in their lifecycle behavior.
  if app.isNil or app.started or app.starting:
    raise newException(ValueError,
      resource & " must be registered before application startup")

proc addMiddleware*(app: Application, middleware: Middleware) =
  ## Global middleware runs in registration order around the route handler.
  app.ensureRegistrationWindow("Middleware")
  app.middlewares.add(middleware)

proc configureDatabasePool*(app: Application,
                            pool: DatabaseConnectionPool) =
  ## Inject the pool before startup. The application then owns request-scoped
  ## borrowing and closes idle/active connections during shutdown.
  if app.isNil or pool.isNil:
    raise newException(ValueError, "Application and database pool are required")
  if app.started or app.starting:
    raise newException(ValueError,
      "Database pool must be configured before application startup")
  app.databasePool = pool

proc configureTemplateAdapter*(app: Application,
                               adapter: TemplateAdapter) =
  ## Configure rendering before startup. Keeping this as an application-owned
  ## composition step makes template replacement explicit and prevents a
  ## request from observing a renderer being swapped mid-lifecycle.
  if app.isNil or adapter.isNil:
    raise newException(ValueError, "Application and template adapter are required")
  if app.started or app.starting:
    raise newException(ValueError,
      "Template adapter must be configured before application startup")
  app.templateAdapter = adapter

proc renderTemplateResponse*(app: Application, name: string,
                             context: TemplateRenderContext,
                             status = Http200): Response =
  ## Application owns the HTTP representation while the adapter owns the
  ## rendering implementation. This single bridge gives all engines the same
  ## response content type and lifecycle boundary.
  if app.isNil or app.templateAdapter.isNil:
    raise newException(ValueError, "Application template adapter is required")
  htmlResponse(app.templateAdapter.renderTemplate(name, context), status)

proc configureMigrations*(app: Application, registry: MigrationRegistry,
                          sqlitePath = ".mahanaim.sqlite") =
  ## Migration definitions and the database path are explicit application
  ## inputs; the CLI never scans source files or guesses project modules.
  if app.isNil or registry.isNil or sqlitePath.strip().len == 0:
    raise newException(ValueError,
      "Application, migration registry, and SQLite path are required")
  if app.started or app.starting:
    raise newException(ValueError,
      "Migrations must be configured before application startup")
  app.migrationRegistry = registry
  app.migrationDatabasePath = sqlitePath

proc configureMigrationDatabase*(app: Application,
                                 provider: MigrationDatabaseProvider) =
  ## Inject the CLI database backend explicitly. The default remains SQLite;
  ## custom providers are application-owned and must be configured before boot.
  if app.isNil or provider.open.isNil or provider.close.isNil or
      provider.runMigrations.isNil:
    raise newException(ValueError,
      "Application migration database provider is incomplete")
  if app.started or app.starting:
    raise newException(ValueError,
      "Migration database provider must be configured before application startup")
  app.migrationDatabaseProvider = provider

proc configureSeeds*(app: Application, registry: SeedRegistry) =
  ## Seed handlers are explicit application inputs and must be configured
  ## before startup just like migrations and database pools.
  if app.isNil or registry.isNil:
    raise newException(ValueError, "Application and seed registry are required")
  if app.started or app.starting:
    raise newException(ValueError,
      "Seeds must be configured before application startup")
  app.seedRegistry = registry

proc configureDurableJobs*(app: Application, store: DurableJobStore,
                           registry: DurableJobRegistry) =
  ## Durable jobs are application-owned: persisted data is inert until the
  ## application supplies a named handler registry and its bounded executor.
  ## Requiring configuration before startup keeps command and worker behavior
  ## identical in embedding hosts and the standalone CLI.
  if app.isNil or store.isNil or registry.isNil:
    raise newException(ValueError,
      "Application, durable job store, and registry are required")
  if app.started or app.starting:
    raise newException(ValueError,
      "Durable jobs must be configured before application startup")
  app.durableJobStore = store
  app.durableJobRegistry = registry

proc registerCommand*(app: Application, command: CommandDefinition) =
  ## Registration is fail-fast so duplicate CLI names cannot shadow commands.
  if app.isNil or app.started or app.starting:
    raise newException(ValueError,
      "Commands must be registered before application startup")
  if command.name.strip().len == 0 or command.handler.isNil:
    raise newException(ValueError, "Command requires a name and handler")
  if app.commands.hasKey(command.name):
    raise newException(ValueError, "Duplicate command: " & command.name)
  app.commands[command.name] = command

proc configureAdminUserCreator*(app: Application,
                                creator: AdminUserCreator) =
  ## Configure provisioning before startup so a standalone command cannot
  ## accidentally mutate an application with a different runtime policy.
  if app.isNil or creator.isNil:
    raise newException(ValueError, "Application and admin user creator are required")
  if app.started or app.starting:
    raise newException(ValueError,
      "Admin user creator must be configured before application startup")
  if not app.adminUserCreator.isNil:
    raise newException(ValueError, "Admin user creator is already configured")
  app.adminUserCreator = creator

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
  if app.isNil or app.started or app.starting:
    raise newException(ValueError,
      "Admin extensions must be registered before application startup")
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

proc newApplicationModule*(name: string): ApplicationModule =
  ## Start with an empty, explicit module. Declarations below are deliberately
  ## separate calls so generated and hand-written applications remain easy to
  ## review without macro or global discovery.
  if name.strip().len == 0:
    raise newException(ValueError, "Application module name is required")
  ApplicationModule(name: name, imports: @[], providers: @[], controllers: @[],
    routes: @[], startupHooks: @[], shutdownHooks: @[], exports: @[])

proc importModule*(module, dependency: ApplicationModule) =
  if module.isNil or dependency.isNil:
    raise newException(ValueError, "Application module import is required")
  if module == dependency:
    raise newException(ValueError, "Application module cannot import itself")
  for existing in module.imports:
    if existing == dependency or existing.name == dependency.name:
      raise newException(ValueError,
        "Duplicate application module import: " & dependency.name)
  module.imports.add(dependency)

proc addModuleProvider*(module: ApplicationModule, name: string,
                        scope: DependencyScope, provider: DependencyProvider,
                        disposer: DependencyDisposer = nil) =
  if module.isNil or name.strip().len == 0 or provider.isNil:
    raise newException(ValueError, "Module provider name and provider are required")
  for existing in module.providers:
    if existing.registration.name == name:
      raise newException(ValueError, "Duplicate module provider: " & name)
  module.providers.add(ModuleProvider(registration: DependencyRegistration(
    name: name, scope: scope, provider: provider, disposer: disposer)))

proc addModuleFactory*(module: ApplicationModule, name: string,
                       scope: DependencyScope, dependencies: openArray[string],
                       factory: DependencyFactory,
                       disposer: DependencyDisposer = nil) =
  if module.isNil or name.strip().len == 0 or factory.isNil:
    raise newException(ValueError, "Module factory name and factory are required")
  var edges: seq[string] = @[]
  for dependency in dependencies:
    edges.add(dependency)
  for existing in module.providers:
    if existing.registration.name == name:
      raise newException(ValueError, "Duplicate module provider: " & name)
  module.providers.add(ModuleProvider(registration: DependencyRegistration(
    name: name, scope: scope, factory: factory, dependencies: edges,
    disposer: disposer)))

proc overrideModuleProvider*(module: ApplicationModule, name: string,
                             scope: DependencyScope, provider: DependencyProvider,
                             disposer: DependencyDisposer = nil) =
  ## An override may only target an imported, exported provider; composition
  ## verifies that condition before any registration reaches the container.
  if module.isNil or name.strip().len == 0 or provider.isNil:
    raise newException(ValueError, "Module override name and provider are required")
  for existing in module.providers:
    if existing.registration.name == name:
      raise newException(ValueError, "Duplicate module provider: " & name)
  module.providers.add(ModuleProvider(registration: DependencyRegistration(
    name: name, scope: scope, provider: provider, disposer: disposer),
    overrideExisting: true))

proc exportProvider*(module: ApplicationModule, name: string) =
  if module.isNil or name.strip().len == 0:
    raise newException(ValueError, "Module export name is required")
  if name in module.exports:
    raise newException(ValueError, "Duplicate module export: " & name)
  module.exports.add(name)

proc addModuleController*(module: ApplicationModule, installer: ModuleInstaller) =
  if module.isNil or installer.isNil:
    raise newException(ValueError, "Module controller installer is required")
  module.controllers.add(installer)

proc addModuleRoute*(module: ApplicationModule, installer: ModuleInstaller) =
  if module.isNil or installer.isNil:
    raise newException(ValueError, "Module route installer is required")
  module.routes.add(installer)

proc onModuleStartup*(module: ApplicationModule, hook: LifecycleHook) =
  if module.isNil or hook.isNil:
    raise newException(ValueError, "Module startup hook is required")
  module.startupHooks.add(hook)

proc onModuleShutdown*(module: ApplicationModule, hook: LifecycleHook) =
  if module.isNil or hook.isNil:
    raise newException(ValueError, "Module shutdown hook is required")
  module.shutdownHooks.add(hook)

proc resolveApplicationModules*(roots: openArray[ApplicationModule]): seq[ApplicationModule] =
  ## Depth-first traversal keeps import order deterministic while diagnosing
  ## duplicate names and cyclic references before installers have side effects.
  var byName = initTable[string, ApplicationModule]()
  var visiting = initTable[string, bool]()
  var visited = initTable[string, bool]()
  let ordered = new seq[ApplicationModule]
  proc visit(module: ApplicationModule) =
    if module.isNil or module.name.strip().len == 0:
      raise newException(ValueError, "Application module is missing a name")
    if byName.hasKey(module.name) and byName[module.name] != module:
      raise newException(ValueError, "Duplicate application module: " & module.name)
    byName[module.name] = module
    if visiting.hasKey(module.name):
      raise newException(ValueError, "Cyclic application module graph: " & module.name)
    if visited.hasKey(module.name):
      return
    visiting[module.name] = true
    for dependency in module.imports:
      visit(dependency)
    visiting.del(module.name)
    visited[module.name] = true
    ordered[].add(module)
  for root in roots:
    visit(root)
  result = ordered[]

proc visibleModuleExports(module: ApplicationModule): seq[string] =
  ## Only direct imported exports enter a module's provider dependency surface.
  ## A transitive dependency must be re-exported deliberately, avoiding the
  ## accidental ambient visibility common in global-container designs.
  for dependency in module.imports:
    for exported in dependency.exports:
      if exported notin result:
        result.add(exported)

proc onStartup*(app: Application, hook: LifecycleHook)
proc onShutdown*(app: Application, hook: LifecycleHook)

proc installModules*(app: Application, roots: openArray[ApplicationModule]) =
  ## Validate all names, exports, overrides, and provider edges before wiring
  ## routes or hooks. A failed composition is therefore recoverable and does
  ## not leave a partially configured application behind.
  app.ensureRegistrationWindow("Application modules")
  let modules = resolveApplicationModules(roots)
  var providedBy = initTable[string, string]()
  for module in modules:
    for provider in module.providers:
      let name = provider.registration.name
      if provider.overrideExisting:
        if not providedBy.hasKey(name) or name notin module.visibleModuleExports():
          raise newException(ValueError,
            "Module override must target an imported exported provider: " & name)
      elif providedBy.hasKey(name):
        raise newException(ValueError, "Duplicate module provider: " & name)
      providedBy[name] = module.name
    for exported in module.exports:
      var declared = false
      for provider in module.providers:
        if provider.registration.name == exported:
          declared = true
      if not declared:
        raise newException(ValueError,
          "Module export is not declared by the module: " & exported)
    let visible = module.visibleModuleExports()
    for provider in module.providers:
      for dependency in provider.registration.dependencies:
        var local = false
        for candidate in module.providers:
          if candidate.registration.name == dependency:
            local = true
        if not local and dependency notin visible:
          raise newException(ValueError,
            "Module provider depends on a non-exported dependency: " & dependency)
  for module in modules:
    for provider in module.providers:
      if provider.overrideExisting:
        app.services.override(provider.registration)
      elif app.services.hasDependency(provider.registration.name):
        raise newException(ValueError,
          "Duplicate application dependency: " & provider.registration.name)
      elif not provider.registration.factory.isNil:
        app.services.provideFactory(provider.registration.name,
          provider.registration.scope, provider.registration.dependencies,
          provider.registration.factory, provider.registration.disposer)
      else:
        app.services.provide(provider.registration.name,
          provider.registration.scope, provider.registration.provider,
          provider.registration.disposer)
    for controller in module.controllers:
      controller(app)
    for route in module.routes:
      route(app)
    for hook in module.startupHooks:
      app.onStartup(hook)
    for hook in module.shutdownHooks:
      app.onShutdown(hook)
    app.moduleNames[module.name] = true

proc hasModule*(app: Application, name: string): bool =
  not app.isNil and app.moduleNames.hasKey(name)

proc addRoute*(app: Application, httpMethod, pattern, name: string,
               handler: Handler, middleware: seq[Middleware] = @[]) =
  ## The generic registration API keeps less common methods available without
  ## multiplying application-specific wrappers for every HTTP verb.
  app.ensureRegistrationWindow("Routes")
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
  app.ensureRegistrationWindow("WebSocket routes")
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
  app.ensureRegistrationWindow("Routes")
  app.router.addRoute(group, httpMethod, pattern, name, handler, middleware)

proc get*(app: Application, group: RouteGroup, pattern, name: string,
          handler: Handler, middleware: seq[Middleware] = @[]) =
  app.addRoute(group, "GET", pattern, name, handler, middleware)

proc post*(app: Application, group: RouteGroup, pattern, name: string,
           handler: Handler, middleware: seq[Middleware] = @[]) =
  app.addRoute(group, "POST", pattern, name, handler, middleware)

proc addSyncRoute*(app: Application, httpMethod, pattern, name: string,
                   handler: SyncHandler,
                   middleware: seq[Middleware] = @[]) =
  ## Generic synchronous registration keeps blocking work on the executor for
  ## every HTTP method instead of forcing PUT/PATCH/DELETE handlers onto the
  ## event loop.
  app.ensureRegistrationWindow("Routes")
  app.router.addRoute(httpMethod, pattern, name, asyncHandler(handler), middleware,
    hekSync, handler)

proc getSync*(app: Application, pattern, name: string, handler: SyncHandler,
              middleware: seq[Middleware] = @[]) =
  ## Register a synchronous handler explicitly so blocking work is visible in
  ## code review and is routed through the application's executor policy.
  app.addSyncRoute("GET", pattern, name, handler, middleware)

proc postSync*(app: Application, pattern, name: string, handler: SyncHandler,
               middleware: seq[Middleware] = @[]) =
  app.addSyncRoute("POST", pattern, name, handler, middleware)

proc putSync*(app: Application, pattern, name: string, handler: SyncHandler,
              middleware: seq[Middleware] = @[]) =
  app.addSyncRoute("PUT", pattern, name, handler, middleware)

proc patchSync*(app: Application, pattern, name: string, handler: SyncHandler,
                middleware: seq[Middleware] = @[]) =
  app.addSyncRoute("PATCH", pattern, name, handler, middleware)

proc deleteSync*(app: Application, pattern, name: string, handler: SyncHandler,
                 middleware: seq[Middleware] = @[]) =
  app.addSyncRoute("DELETE", pattern, name, handler, middleware)

proc onStartup*(app: Application, hook: LifecycleHook) =
  ## Startup hooks are configuration. Rejecting late additions prevents a
  ## hook registered from inside another hook from changing this run's order.
  if app.isNil or app.started or app.starting:
    raise newException(ValueError,
      "Startup hooks must be registered before application startup")
  app.startupHooks.add(hook)

proc onShutdown*(app: Application, hook: LifecycleHook) =
  ## Shutdown ownership is fixed before startup so cleanup remains symmetric
  ## and can be reasoned about even when startup fails halfway through.
  if app.isNil or app.started or app.starting:
    raise newException(ValueError,
      "Shutdown hooks must be registered before application startup")
  app.shutdownHooks.add(hook)

proc onError*(app: Application, handler: ErrorHandler) =
  ## Install an explicit application-level exception policy.
  app.ensureRegistrationWindow("Error handlers")
  app.errorHandler = handler

proc use*(app: Application, plugin: Plugin) =
  ## Plugins are installed before startup and can register routes, middleware,
  ## commands, or future extension points through the Application contract.
  if app.isNil or app.started or app.starting:
    raise newException(ValueError,
      "Plugins must be registered before application startup")
  app.plugins.add(plugin)
  plugin(app)

proc use*(app: Application, plugin: PluginDefinition) =
  ## Manifest plugins are recorded before install so checks and tooling can
  ## inspect registration intent without executing arbitrary plugin code.
  if app.isNil or app.started or app.starting:
    raise newException(ValueError,
      "Plugins must be registered before application startup")
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
  app.ensureRegistrationWindow("Models")
  app.models.registerModel(metadata)

proc provide*(app: Application, name: string, scope: DependencyScope,
              provider: DependencyProvider,
              disposer: DependencyDisposer = nil) =
  ## Plugin-facing wrapper keeps service registration on the application owner.
  app.ensureRegistrationWindow("Dependencies")
  app.services.provide(name, scope, provider, disposer)

proc provideFactory*(app: Application, name: string, scope: DependencyScope,
                     dependencies: openArray[string],
                     factory: DependencyFactory,
                     disposer: DependencyDisposer = nil) =
  ## Application-owned graph registration keeps dependency edges explicit while
  ## preserving the same provider API for plugins and generated applications.
  app.ensureRegistrationWindow("Dependencies")
  app.services.provideFactory(name, scope, dependencies, factory, disposer)

proc resolve*(app: Application, name: string): DependencyService =
  ## Resolution remains explicit so request/task lifecycle owners can decide
  ## when to create and release narrower-scope values.
  app.services.resolve(name)

proc newServiceScope*(app: Application): ServiceContainer =
  ## Request/task adapters create an owned child scope instead of sharing the
  ## application cache. The caller must dispose the returned scope at the end
  ## of its lifecycle, which keeps core services framework-neutral.
  if app.isNil:
    raise newException(ValueError, "Application is required")
  app.services.newChildScope()

proc newTaskServiceScope*(app: Application): ServiceContainer =
  ## Task runners own this scope and must dispose it after every delivery.
  ## The separate API keeps task lifetime visible even though both narrow
  ## scopes share the same deterministic container mechanics.
  if app.isNil:
    raise newException(ValueError, "Application is required")
  app.services.newTaskScope()

proc registerSerializationCodec*(app: Application, wireType: string,
                                 codec: SerializationCodec) =
  ## Serialization plugins register against the application-owned registry;
  ## model serializers can then consume the same codec without a global hook.
  app.ensureRegistrationWindow("Serialization codecs")
  app.serializationRegistry.registerCodec(wireType, codec)

proc registerStorage*(app: Application, name: string, store: ObjectStorage) =
  ## Storage names are explicit dependency keys. A duplicate is rejected so a
  ## plugin cannot silently replace an application's upload or cache backend.
  app.ensureRegistrationWindow("Storage adapters")
  if app.isNil or name.strip().len == 0 or store.isNil:
    raise newException(ValueError, "Storage requires an application, name, and adapter")
  if app.storageAdapters.hasKey(name):
    raise newException(ValueError, "Duplicate storage adapter: " & name)
  app.storageAdapters[name] = store

proc storage*(app: Application, name: string): ObjectStorage =
  ## Lookup remains explicit and returns a stable application-owned adapter.
  if app.isNil or not app.storageAdapters.hasKey(name):
    raise newException(ValueError, "Unknown storage adapter: " & name)
  app.storageAdapters[name]

proc registerAuthBackend*(app: Application, backend: AuthBackend) =
  ## Authentication plugins enter the same ordered policy list used by the
  ## security middleware, preserving one credential negotiation boundary.
  app.ensureRegistrationWindow("Authentication backends")
  app.securityPolicy.addAuthBackend(backend)
  ## `securityMiddleware` captures an immutable policy snapshot by design. It
  ## must be rebuilt after plugin registration so the new backend is effective
  ## for dispatch, rather than merely visible in application metadata.
  if app.middlewares.len == 0:
    app.middlewares.add(securityMiddleware(app.securityPolicy))
  else:
    app.middlewares[0] = securityMiddleware(app.securityPolicy)

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
  ## Network adapters delegate here. One request service scope is created before
  ## any route or middleware runs and disposed after the future completes, while
  ## a borrowed database connection is released on every route, 404, 405,
  ## timeout, and exception path through the nested finally block. Response
  ## negotiation is centralized here so in-process clients and every transport
  ## adapter observe the same selected representation.
  let serviceScope = app.services.newRequestScope()
  var requestWithServices = request
  requestWithServices.services = serviceScope
  defer: serviceScope.dispose()
  if app.databasePool.isNil:
    return conditionalResponse(requestWithServices,
      negotiateResponse(requestWithServices,
        await app.dispatchInternal(requestWithServices)))
  let database = app.databasePool.acquire()
  var requestWithDatabase = requestWithServices
  requestWithDatabase.database = database
  try:
    return conditionalResponse(requestWithDatabase,
      negotiateResponse(requestWithDatabase,
        await app.dispatchInternal(requestWithDatabase)))
  finally:
    app.databasePool.release(database)

proc startup*(app: Application) =
  ## Hooks execute once and in registration order.
  if app.started or app.starting:
    return
  app.starting = true
  try:
    for hook in app.startupHooks:
      hook()
    app.observability.setReady(true)
    app.started = true
  finally:
    ## A failed startup must leave the application configurable only through
    ## the normal pre-start path and must not strand the transition flag.
    app.starting = false

proc shutdown*(app: Application) =
  ## Shutdown is idempotent so signal handlers can safely call it repeatedly.
  if not app.started:
    return
  for index in countdown(app.shutdownHooks.high, 0):
    app.shutdownHooks[index]()
  app.observability.setReady(false)
  if app.databasePool != nil:
    app.databasePool.close()
  if app.durableJobStore != nil:
    app.durableJobStore.close()
  app.services.dispose()
  ## Keep explicit registrations available for post-shutdown health dispatches
  ## and future restart; all created service instances were already released.
  app.services.reopen()
  app.started = false

## Application lifecycle and middleware dispatcher.

import std/[asyncdispatch, httpcore, options]
import ./core
import ./router
import ./config

type
  LifecycleHook* = proc ()

  Application* = ref object
    ## Owns routing and lifecycle state for one application instance.
    config*: AppConfig
    router*: Router
    middlewares*: seq[Middleware]
    startupHooks*: seq[LifecycleHook]
    shutdownHooks*: seq[LifecycleHook]
    errorHandler*: ErrorHandler
    plugins*: seq[Plugin]
    started*: bool

  ErrorHandler* = proc (request: Request,
                        error: ref CatchableError): Future[Response] {.gcsafe.}
  Plugin* = proc (app: Application)

proc defaultErrorHandler(request: Request,
                         error: ref CatchableError): Future[Response] {.async, gcsafe.}

proc newApplication*(config = defaultConfig()): Application =
  ## Construct an isolated app instance; this is important for test isolation.
  new(result)
  result.config = config
  result.router = initRouter()
  result.middlewares = @[]
  result.startupHooks = @[]
  result.shutdownHooks = @[]
  result.errorHandler = defaultErrorHandler
  result.plugins = @[]
  result.started = false

proc defaultErrorHandler(request: Request,
                         error: ref CatchableError): Future[Response] {.async, gcsafe.} =
  ## Never expose exception text by default; custom handlers can log it safely
  ## after passing through the application's secret redaction policy.
  discard request
  discard error
  return textResponse("Internal Server Error", Http500)

proc addMiddleware*(app: Application, middleware: Middleware) =
  ## Global middleware runs in registration order around the route handler.
  app.middlewares.add(middleware)

proc get*(app: Application, pattern, name: string, handler: Handler,
          middleware: seq[Middleware] = @[]) =
  app.router.addRoute("GET", pattern, name, handler, middleware)

proc post*(app: Application, pattern, name: string, handler: Handler,
           middleware: seq[Middleware] = @[]) =
  app.router.addRoute("POST", pattern, name, handler, middleware)

proc getSync*(app: Application, pattern, name: string, handler: SyncHandler,
              middleware: seq[Middleware] = @[]) =
  ## Register a synchronous handler explicitly so blocking work is visible in
  ## code review and can later be routed through an executor policy.
  app.router.addRoute("GET", pattern, name, asyncHandler(handler), middleware)

proc postSync*(app: Application, pattern, name: string, handler: SyncHandler,
               middleware: seq[Middleware] = @[]) =
  ## POST counterpart to getSync; both use the same adapter contract.
  app.router.addRoute("POST", pattern, name, asyncHandler(handler), middleware)

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

proc compose(middlewares: seq[Middleware], endpoint: Handler): Handler =
  ## Compose middleware from right to left, making each layer responsible for
  ## exactly one concern and preserving onion-style request/response flow.
  result = endpoint
  for index in countdown(middlewares.high, 0):
    let current = middlewares[index]
    let next = result
    result = proc(request: Request): Future[Response] {.gcsafe.} =
      current(request, next)

proc notFoundHandler(request: Request): Future[Response] {.async, gcsafe.} =
  ## Keep 404 behavior explicit and replaceable in a later error-handler API.
  discard request
  return textResponse("Not Found", Http404)

proc methodNotAllowedHandler(request: Request): Future[Response] {.async, gcsafe.} =
  discard request
  return textResponse("Method Not Allowed", Http405)

proc invoke(app: Application, request: Request, handler: Handler): Future[Response] {.async.} =
  ## One guarded invocation path prevents sync, async, and plugin routes from
  ## drifting into different exception behavior.
  try:
    return await handler(request)
  except CatchableError as error:
    return await app.errorHandler(request, error)

proc dispatch*(app: Application, request: Request): Future[Response] {.async.} =
  ## Dispatch an in-process request. Network adapters can delegate to this API.
  var matchedRoute: Option[Route] = none(Route)
  for route in app.router.routes:
    if route.pattern == request.path:
      matchedRoute = some(route)
      break

  if matchedRoute.isNone:
    # Try parameterized routes after the cheap exact-path check.
    for route in app.router.routes:
      if route.httpMethod == request.httpMethod:
        let params = extractParams(route.pattern, request.path)
        if params.isSome:
          var requestWithParams = request
          requestWithParams.pathParams = params.get()
          var layers = app.middlewares
          layers.add(route.middleware)
          return await app.invoke(requestWithParams, compose(layers, route.handler))
    return await notFoundHandler(request)

  let route = matchedRoute.get()
  if route.httpMethod != request.httpMethod:
    return await methodNotAllowedHandler(request)
  var layers = app.middlewares
  layers.add(route.middleware)
  return await app.invoke(request, compose(layers, route.handler))

proc startup*(app: Application) =
  ## Hooks execute once and in registration order.
  if app.started:
    return
  for hook in app.startupHooks:
    hook()
  app.started = true

proc shutdown*(app: Application) =
  ## Shutdown is idempotent so signal handlers can safely call it repeatedly.
  if not app.started:
    return
  for index in countdown(app.shutdownHooks.high, 0):
    app.shutdownHooks[index]()
  app.started = false

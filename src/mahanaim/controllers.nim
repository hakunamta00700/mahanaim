## Class-based controller bridge for the framework-neutral Application.
##
## Controllers own action dispatch and application state; Application continues
## to own route matching, middleware, request scopes, and response handling.
## Keeping this bridge small avoids introducing a second routing system while
## still giving applications a conventional class-based extension point.

import std/[asyncdispatch, strutils]
import ./application
import ./core

type
  Controller* = ref object of RootObj
    ## The base type intentionally carries no framework state. Concrete
    ## controllers may add repositories or services through their own DI-aware
    ## construction path without making the router know their fields.

method handle*(controller: Controller, action: string,
              request: Request): Future[Response] {.base, gcsafe.} =
  ## Fail explicitly when an application registers a base controller instead
  ## of a concrete implementation. The action string is kept explicit so
  ## route declarations remain inspectable and deterministic.
  discard controller
  discard request
  raise newException(ValueError,
    "Controller action is not implemented: " & action)

proc addControllerRoute*(app: Application, controller: Controller,
                         httpMethod, pattern, name, action: string,
                         middleware: seq[Middleware] = @[]) =
  ## The route remains an ordinary Application route. Only the final handler
  ## invocation crosses into the controller, preserving middleware ordering,
  ## request-scoped DI, error handling, and all adapter contracts.
  if app.isNil or controller.isNil:
    raise newException(ValueError, "Application and controller are required")
  if action.strip().len == 0:
    raise newException(ValueError, "Controller action is required")
  let target = controller
  let selectedAction = action
  let handler: Handler = proc(request: Request): Future[Response] {.async, gcsafe.} =
    await target.handle(selectedAction, request)
  app.addRoute(httpMethod, pattern, name, handler, middleware)

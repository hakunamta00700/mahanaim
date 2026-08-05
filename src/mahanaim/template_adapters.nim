## Backend-neutral template rendering boundary.
##
## The built-in TemplateEngine remains useful for the default deployment, but
## applications should be able to replace it without teaching route, admin, or
## response code about another template library. This module owns only the
## narrow render contract; template loading, escaping, and engine lifecycle
## stay with the selected adapter.

import ./templates

type
  TemplateAdapter* = ref object of RootObj
    ## The base type deliberately carries no source or cache state. A concrete
    ## adapter may own any engine-specific resources behind this boundary.

  TemplateRenderCallback* = proc(name: string,
                                  context: TemplateRenderContext): string
                                  {.gcsafe.}

  CallbackTemplateAdapter* = ref object of TemplateAdapter
    callback: TemplateRenderCallback

  TemplateEngineAdapter* = ref object of TemplateAdapter
    engine: TemplateEngine

method renderTemplate*(adapter: TemplateAdapter, name: string,
                       context: TemplateRenderContext): string {.base.} =
  ## Fail explicitly instead of silently returning an empty response when an
  ## application forgets to choose a concrete renderer.
  discard adapter
  discard context
  raise newException(ValueError,
    "Template adapter does not implement renderTemplate: " & name)

proc newCallbackTemplateAdapter*(callback: TemplateRenderCallback):
    CallbackTemplateAdapter =
  ## Callback adapters are the smallest integration point for an external
  ## engine; provider-specific parsing and dependency ownership remain outside
  ## the framework core.
  if callback.isNil:
    raise newException(ValueError, "Template render callback is required")
  new(result)
  result.callback = callback

method renderTemplate*(adapter: CallbackTemplateAdapter, name: string,
                       context: TemplateRenderContext): string =
  if adapter.isNil or adapter.callback.isNil:
    raise newException(ValueError, "Callback template adapter is not ready")
  adapter.callback(name, context)

proc newTemplateEngineAdapter*(engine: TemplateEngine): TemplateEngineAdapter =
  ## Wrap the built-in engine without changing its existing public API. This
  ## makes the default and alternate engines interchangeable at application
  ## composition boundaries.
  if engine.isNil:
    raise newException(ValueError, "Template engine is required")
  new(result)
  result.engine = engine

method renderTemplate*(adapter: TemplateEngineAdapter, name: string,
                       context: TemplateRenderContext): string =
  if adapter.isNil or adapter.engine.isNil:
    raise newException(ValueError, "Template engine adapter is not ready")
  adapter.engine.render(name, context)

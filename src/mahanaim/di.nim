## Minimal dependency-injection contract for plugins and application code.
##
## Providers return `DependencyService` values so the core does not depend on
## a concrete service type. Application scope is cached; request/task scopes
## are factories and are intentionally resolved explicitly by their owner.

import std/[strutils, tables]

type
  DependencyScope* = enum
    dependencyApplication
    dependencyRequest
    dependencyTask

  DependencyService* = ref object of RootObj
    ## Marker base keeps service ownership type-safe at the framework boundary.

  DependencyProvider* = proc (): DependencyService {.gcsafe.}

  DependencyRegistration* = object
    name*: string
    scope*: DependencyScope
    provider*: DependencyProvider

  ServiceContainer* = ref object
    registrations*: Table[string, DependencyRegistration]
    applicationInstances*: Table[string, DependencyService]

proc newServiceContainer*(): ServiceContainer =
  new(result)
  result.registrations = initTable[string, DependencyRegistration]()
  result.applicationInstances = initTable[string, DependencyService]()

proc provide*(container: ServiceContainer, name: string,
              scope: DependencyScope,
              provider: DependencyProvider) =
  ## Registration is explicit and duplicate names fail before startup.
  if container.isNil or name.strip().len == 0:
    raise newException(ValueError, "Dependency name cannot be empty")
  if provider.isNil:
    raise newException(ValueError, "Dependency provider cannot be nil")
  if container.registrations.hasKey(name):
    raise newException(ValueError, "Duplicate dependency: " & name)
  container.registrations[name] = DependencyRegistration(name: name,
    scope: scope, provider: provider)

proc resolve*(container: ServiceContainer,
              name: string): DependencyService =
  ## Application scope caches one instance; narrower scopes remain factories.
  if container.isNil or not container.registrations.hasKey(name):
    raise newException(ValueError, "Unknown dependency: " & name)
  let registration = container.registrations[name]
  if registration.scope == dependencyApplication and
      container.applicationInstances.hasKey(name):
    return container.applicationInstances[name]
  result = registration.provider()
  if result.isNil:
    raise newException(ValueError, "Dependency provider returned nil: " & name)
  if registration.scope == dependencyApplication:
    container.applicationInstances[name] = result

proc hasDependency*(container: ServiceContainer, name: string): bool =
  not container.isNil and container.registrations.hasKey(name)

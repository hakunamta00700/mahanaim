## Minimal dependency-injection contract for plugins and application code.
##
## Providers return `DependencyService` values so the core does not depend on
## a concrete service type. Application scope is cached; request/task scopes
## are owned by explicit child containers and disposed by their lifecycle owner.

import std/[strutils, tables]

type
  DependencyScope* = enum
    dependencyApplication
    dependencyRequest
    dependencyTask

  DependencyService* = ref object of RootObj
    ## Marker base keeps service ownership type-safe at the framework boundary.

  DependencyProvider* = proc (): DependencyService {.gcsafe.}
  DependencyFactory* = proc(dependencies: seq[DependencyService]):
    DependencyService {.gcsafe.}
  DependencyDisposer* = proc(service: DependencyService) {.gcsafe.}

  DependencyRegistration* = object
    name*: string
    scope*: DependencyScope
    provider*: DependencyProvider
    factory*: DependencyFactory
    dependencies*: seq[string]
    disposer*: DependencyDisposer

  ServiceContainer* = ref object
    registrations*: Table[string, DependencyRegistration]
    applicationInstances*: Table[string, DependencyService]
    ownedInstances: Table[string, DependencyService]
    instanceOrder: seq[string]
    ownedInstanceOrder: seq[string]
    resolving: Table[string, bool]
    parent*: ServiceContainer
    children: seq[ServiceContainer]
    disposed: bool

proc newServiceContainer*(): ServiceContainer =
  new(result)
  result.registrations = initTable[string, DependencyRegistration]()
  result.applicationInstances = initTable[string, DependencyService]()
  result.resolving = initTable[string, bool]()
  result.ownedInstances = initTable[string, DependencyService]()
  result.instanceOrder = @[]
  result.ownedInstanceOrder = @[]
  result.children = @[]

proc provide*(container: ServiceContainer, name: string,
              scope: DependencyScope,
              provider: DependencyProvider,
              disposer: DependencyDisposer = nil) =
  ## Registration is explicit and duplicate names fail before startup.
  if container.isNil or container.disposed or name.strip().len == 0:
    raise newException(ValueError,
      "Dependency container is unavailable or name is empty")
  if provider.isNil:
    raise newException(ValueError, "Dependency provider cannot be nil")
  if container.registrations.hasKey(name):
    raise newException(ValueError, "Duplicate dependency: " & name)
  container.registrations[name] = DependencyRegistration(name: name,
    scope: scope, provider: provider, disposer: disposer)

proc validateDependencies(dependencies: openArray[string]) =
  ## Reject malformed graph edges during registration; cycle detection remains
  ## a resolution concern because registrations may be assembled incrementally.
  var seen = initTable[string, bool]()
  for dependency in dependencies:
    if dependency.strip().len == 0:
      raise newException(ValueError, "Dependency edge name cannot be empty")
    if seen.hasKey(dependency):
      raise newException(ValueError,
        "Duplicate dependency edge: " & dependency)
    seen[dependency] = true

proc provideFactory*(container: ServiceContainer, name: string,
                     scope: DependencyScope,
                     dependencies: openArray[string],
                     factory: DependencyFactory,
                     disposer: DependencyDisposer = nil) =
  ## Register a node whose inputs are resolved through the same container. The
  ## factory receives values, not container internals, preserving a narrow
  ## dependency boundary and making graph resolution testable in isolation.
  if container.isNil or container.disposed or name.strip().len == 0:
    raise newException(ValueError,
      "Dependency container is unavailable or name is empty")
  if factory.isNil:
    raise newException(ValueError, "Dependency factory cannot be nil")
  if container.registrations.hasKey(name):
    raise newException(ValueError, "Duplicate dependency: " & name)
  validateDependencies(dependencies)
  var edges: seq[string] = @[]
  for dependency in dependencies:
    edges.add(dependency)
  container.registrations[name] = DependencyRegistration(name: name,
    scope: scope, factory: factory, dependencies: edges, disposer: disposer)

proc newChildScope*(parent: ServiceContainer): ServiceContainer =
  ## A child owns request/task instances while delegating application-scoped
  ## values to the root. Registrations are copied as values so plugins cannot
  ## mutate a live parent's registry through a child scope.
  if parent.isNil or parent.disposed:
    raise newException(ValueError, "Parent dependency container is unavailable")
  result = newServiceContainer()
  result.parent = parent
  for name, registration in parent.registrations:
    result.registrations[name] = registration
  parent.children.add(result)

proc resolve*(container: ServiceContainer,
              name: string): DependencyService =
  ## Resolve one graph node and keep cycle state local to the current request.
  if container.isNil or container.disposed or
      not container.registrations.hasKey(name):
    raise newException(ValueError, "Unknown dependency: " & name)
  let registration = container.registrations[name]
  if registration.scope == dependencyApplication and not container.parent.isNil:
    return container.parent.resolve(name)
  if registration.scope == dependencyApplication and
      container.applicationInstances.hasKey(name):
    return container.applicationInstances[name]
  if registration.scope != dependencyApplication and not container.parent.isNil and
      container.ownedInstances.hasKey(name):
    return container.ownedInstances[name]
  if container.resolving.hasKey(registration.name):
    raise newException(ValueError,
      "Cyclic dependency graph at: " & registration.name)
  container.resolving[registration.name] = true
  try:
    if not registration.factory.isNil:
      var dependencies: seq[DependencyService] = @[]
      for dependency in registration.dependencies:
        dependencies.add(container.resolve(dependency))
      result = registration.factory(dependencies)
    else:
      if registration.provider.isNil:
        raise newException(ValueError,
          "Dependency registration has no provider: " & registration.name)
      result = registration.provider()
    if result.isNil:
      raise newException(ValueError,
        "Dependency provider returned nil: " & registration.name)
  finally:
    container.resolving.del(registration.name)
  if registration.scope == dependencyApplication:
    container.applicationInstances[name] = result
    container.instanceOrder.add(name)
  elif not container.parent.isNil:
    container.ownedInstances[name] = result
    container.ownedInstanceOrder.add(name)

proc dispose*(container: ServiceContainer) =
  ## Dispose children before parent-owned services. The operation is idempotent
  ## so shutdown paths can safely call it from multiple lifecycle hooks.
  if container.isNil or container.disposed:
    return
  for index in countdown(container.children.high, 0):
    container.children[index].dispose()
  container.children.setLen(0)
  for index in countdown(container.instanceOrder.high, 0):
    let name = container.instanceOrder[index]
    let registration = container.registrations[name]
    if not registration.disposer.isNil:
      registration.disposer(container.applicationInstances[name])
  container.applicationInstances.clear()
  container.instanceOrder.setLen(0)
  for index in countdown(container.ownedInstanceOrder.high, 0):
    let name = container.ownedInstanceOrder[index]
    let registration = container.registrations[name]
    if not registration.disposer.isNil:
      registration.disposer(container.ownedInstances[name])
  container.ownedInstances.clear()
  container.ownedInstanceOrder.setLen(0)
  container.disposed = true

proc hasDependency*(container: ServiceContainer, name: string): bool =
  not container.isNil and not container.disposed and
    container.registrations.hasKey(name)

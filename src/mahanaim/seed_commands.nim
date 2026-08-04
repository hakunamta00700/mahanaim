## Explicit application seed registry.
##
## Seeds are data setup operations, not schema migrations. The registry keeps
## them visible and ordered while the DatabaseAdapter owns transaction
## semantics; providers should make their writes idempotent for repeatable
## development and deployment runs.

import std/strutils
import ./database

type
  SeedHandler* = proc(adapter: DatabaseAdapter) {.gcsafe.}

  SeedDefinition* = object
    name*: string
    handler*: SeedHandler

  SeedRegistry* = ref object
    definitions: seq[SeedDefinition]

proc newSeedRegistry*(): SeedRegistry =
  ## Fresh registries keep application and test seed state isolated.
  new(result)
  result.definitions = @[]

proc registerSeed*(registry: SeedRegistry, seed: SeedDefinition) =
  ## Duplicate names are rejected so deployment order cannot silently change.
  if registry.isNil or seed.name.strip().len == 0 or seed.handler.isNil:
    raise newException(ValueError, "Seed registry, name, and handler are required")
  for existing in registry.definitions:
    if existing.name == seed.name:
      raise newException(ValueError, "Duplicate seed: " & seed.name)
  registry.definitions.add(seed)

proc runSeeds*(registry: SeedRegistry, adapter: DatabaseAdapter): seq[string] =
  ## Execute the complete seed batch atomically. There is deliberately no
  ## hidden seed-history table: idempotency belongs to the application provider
  ## and remains portable across database backends.
  if registry.isNil or adapter.isNil:
    raise newException(ValueError, "Seed registry and database adapter are required")
  adapter.begin()
  try:
    for seed in registry.definitions:
      seed.handler(adapter)
      result.add(seed.name)
    adapter.commit()
  except CatchableError:
    adapter.rollback()
    raise

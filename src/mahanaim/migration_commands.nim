## Migration command orchestration shared by CLI and embedding applications.
##
## Parsing is kept separate from database access so a future project CLI can
## load application-owned migration definitions without making the framework
## guess filesystem conventions or silently mutate the wrong database.

import std/[options, strutils]
import ./database
import ./models
import ./sqlite_adapter

type
  MigrationCommandKind* = enum
    migrationCommandStatus
    migrationCommandUp
    migrationCommandRollback

  MigrationCommand* = object
    ## A validated command intent; execution remains an adapter concern.
    kind*: MigrationCommandKind

  MigrationCommandResult* = object
    ## Stable output data lets human and machine-facing CLIs share a runner.
    kind*: MigrationCommandKind
    applied*: seq[string]
    rolledBack*: Option[string]

  MigrationDefinitionProvider* = proc(): seq[Migration] {.gcsafe.}

  MigrationRegistry* = ref object
    ## Project code registers definitions explicitly; the framework never
    ## scans arbitrary files or executes imports as a hidden side effect.
    providers: seq[MigrationDefinitionProvider]

  MigrationDiffKind* = enum
    migrationMissingTable
    migrationMissingField
    migrationExtraField
    migrationMissingIndex
    migrationChangedField

  MigrationDiff* = object
    ## Diff results are reviewable data and do not mutate a database.
    kind*: MigrationDiffKind
    table*: string
    name*: string
    detail*: string

proc newMigrationRegistry*(): MigrationRegistry =
  ## A fresh registry keeps tests and application modules isolated.
  new(result)
  result.providers = @[]

proc registerMigrations*(registry: MigrationRegistry,
                         provider: MigrationDefinitionProvider) =
  ## Registration order is preserved so generated definitions remain
  ## deterministic and can be reviewed before execution.
  if registry.isNil or provider.isNil:
    raise newException(ValueError, "Migration registry and provider are required")
  registry.providers.add(provider)

proc loadMigrations*(registry: MigrationRegistry): seq[Migration] =
  ## Flatten project-owned providers into one command input without touching DB.
  if registry.isNil:
    raise newException(ValueError, "Migration registry is required")
  for provider in registry.providers:
    for migration in provider():
      result.add(migration)

proc migrationFromMetadata*(metadata: ModelMetadata,
                            name: string): Migration =
  ## Convert one metadata declaration into a reviewable migration. The existing
  ## low-level compiler supports one create-table field, so remaining fields
  ## become explicit ADD COLUMN operations instead of silently losing schema.
  if metadata.tableName.strip().len == 0 or name.strip().len == 0:
    raise newException(ValueError, "Metadata table and migration name are required")
  if metadata.fields.len == 0:
    raise newException(ValueError, "Metadata migration requires at least one field")
  result.name = name
  result.up.add(MigrationOperation(kind: migrationCreateTable,
    table: metadata.tableName, field: metadata.fields[0]))
  if metadata.fields.len > 1:
    for field in metadata.fields[1 .. ^1]:
      result.up.add(MigrationOperation(kind: migrationAddColumn,
        table: metadata.tableName, field: field))
  for index in metadata.indexes:
    result.up.add(MigrationOperation(kind: migrationCreateIndex,
      table: metadata.tableName, index: index))
  result.down.add(MigrationOperation(kind: migrationDropTable,
    table: metadata.tableName))

proc diffModelMetadata*(current, desired: ModelMetadata): seq[MigrationDiff] =
  ## Compare declarations only; applying a diff remains an explicit migration
  ## author decision, which prevents an automated check from dropping data.
  if current.tableName != desired.tableName:
    result.add(MigrationDiff(kind: migrationMissingTable,
      table: desired.tableName, name: desired.name,
      detail: "model table changed from " & current.tableName))
  for field in desired.fields:
    let existing = current.field(field.name)
    if existing.isNone:
      result.add(MigrationDiff(kind: migrationMissingField,
        table: desired.tableName, name: field.name,
        detail: "field is present in desired metadata only"))
    elif existing.get().columnName != field.columnName or
         existing.get().kind != field.kind:
      result.add(MigrationDiff(kind: migrationChangedField,
        table: desired.tableName, name: field.name,
        detail: "field column or value kind changed"))
  for field in current.fields:
    if desired.field(field.name).isNone:
      result.add(MigrationDiff(kind: migrationExtraField,
        table: current.tableName, name: field.name,
        detail: "field is present in current metadata only"))
  for index in desired.indexes:
    var found = false
    for existing in current.indexes:
      if existing.name == index.name and existing.fields == index.fields and
         existing.unique == index.unique:
        found = true
        break
    if not found:
      result.add(MigrationDiff(kind: migrationMissingIndex,
        table: desired.tableName, name: index.name,
        detail: "index is present in desired metadata only"))

proc schemaMatches*(current, desired: ModelMetadata): bool =
  ## CI and CLI checks need a boolean gate while review tools need full diffs.
  diffModelMetadata(current, desired).len == 0

proc parseMigrationCommand*(arguments: openArray[string]): MigrationCommand =
  ## Parse only the migration subcommand, leaving database/config parsing to
  ## the application boundary that owns those resources.
  if arguments.len != 1:
    raise newException(ValueError,
      "migration command must be exactly one of: status, migrate, up, rollback")
  case arguments[0].toLowerAscii()
  of "status": MigrationCommand(kind: migrationCommandStatus)
  of "migrate", "up": MigrationCommand(kind: migrationCommandUp)
  of "rollback": MigrationCommand(kind: migrationCommandRollback)
  else:
    raise newException(ValueError, "unknown migration command: " & arguments[0])

proc executeMigrationCommand*(adapter: SqliteDatabaseAdapter,
                             migrations: openArray[Migration],
                             command: MigrationCommand): MigrationCommandResult =
  ## Keep migration history mutations inside the adapter's transaction rules.
  if adapter.isNil:
    raise newException(ValueError, "migration adapter is required")
  result.kind = command.kind
  case command.kind
  of migrationCommandStatus:
    result.applied = adapter.appliedMigrations()
  of migrationCommandUp:
    result.applied = adapter.migrate(migrations)
  of migrationCommandRollback:
    result.rolledBack = adapter.rollbackLatest(migrations)

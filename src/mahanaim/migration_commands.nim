## Migration command orchestration shared by CLI and embedding applications.
##
## Parsing is kept separate from database access so a future project CLI can
## load application-owned migration definitions without making the framework
## guess filesystem conventions or silently mutate the wrong database.

import std/[options, strutils]
import ./database
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

proc parseMigrationCommand*(arguments: openArray[string]): MigrationCommand =
  ## Parse only the migration subcommand, leaving database/config parsing to
  ## the application boundary that owns those resources.
  if arguments.len != 1:
    raise newException(ValueError,
      "migration command must be exactly one of: status, up, rollback")
  case arguments[0].toLowerAscii()
  of "status": MigrationCommand(kind: migrationCommandStatus)
  of "up": MigrationCommand(kind: migrationCommandUp)
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

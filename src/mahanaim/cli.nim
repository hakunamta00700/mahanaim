## Application-aware command frontend.
##
## The framework owns parsing and adapter lifecycle, while the application owns
## migration definitions and custom commands. Keeping those responsibilities
## separate lets a generated project and an embedding host use the same CLI
## behavior without hidden module discovery.

import std/[options, strutils, tables]
import ./application
import ./migration_commands
import ./sqlite_adapter

proc cliArguments(arguments: openArray[string]): seq[string] =
  ## Copy borrowed command arguments before they cross a frontend boundary.
  for argument in arguments:
    result.add(argument)

proc runDatabaseCli*(app: Application, arguments: openArray[string]): int =
  ## Execute the built-in SQLite migration command using the app-owned registry.
  ## PostgreSQL remains an adapter-specific follow-up until its live contract is
  ## available; this path never silently falls back to a different backend.
  if app.isNil or app.migrationRegistry.isNil:
    raise newException(ValueError, "Application migration registry is required")
  if arguments.len < 1 or arguments.len > 2:
    raise newException(ValueError,
      "db command must be: db status|up|rollback [sqlite-path]")
  var commandArgs = @[arguments[0]]
  let path = if arguments.len == 2: arguments[1] else: app.migrationDatabasePath
  if path.strip().len == 0:
    raise newException(ValueError, "SQLite database path cannot be empty")
  let command = parseMigrationCommand(commandArgs)
  let adapter = newSqliteDatabaseAdapter(path)
  defer: adapter.close()
  let migrations = app.migrationRegistry.loadMigrations()
  let outcome = executeMigrationCommand(adapter, migrations, command)
  case outcome.kind
  of migrationCommandStatus:
    for name in outcome.applied:
      echo name
  of migrationCommandUp:
    for name in outcome.applied:
      echo "applied " & name
  of migrationCommandRollback:
    if outcome.rolledBack.isSome:
      echo "rolled back " & outcome.rolledBack.get()
  0

proc runCli*(app: Application, arguments: openArray[string]): int =
  ## Dispatch built-in database commands first, then application-owned
  ## extension commands. Unknown commands fail instead of being ignored.
  if app.isNil:
    raise newException(ValueError, "Application is required")
  let copied = cliArguments(arguments)
  if copied.len == 0 or copied[0].toLowerAscii() in ["help", "--help", "-h"]:
    echo "mahanaim <command>"
    echo "  db status|up|rollback [sqlite-path]  Run application migrations"
    for name, definition in app.commands:
      echo "  " & name & "  " & definition.description
    return 0
  case copied[0].toLowerAscii()
  of "db":
    if copied.len == 1:
      raise newException(ValueError,
        "db command must be: db status|up|rollback [sqlite-path]")
    return runDatabaseCli(app, copied[1 .. ^1])
  else:
    if app.commands.hasKey(copied[0]):
      return app.runCommand(copied[0], copied[1 .. ^1])
    raise newException(ValueError, "Unknown command: " & copied[0])

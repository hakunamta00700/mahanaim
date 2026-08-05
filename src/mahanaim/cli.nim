## Application-aware command frontend.
##
## The framework owns parsing and adapter lifecycle, while the application owns
## migration definitions and custom commands. Keeping those responsibilities
## separate lets a generated project and an embedding host use the same CLI
## behavior without hidden module discovery.

import std/[asyncdispatch, json, options, os, strutils, tables]
import ./application
import ./checks
import ./database
import ./migration_commands
import ./openapi
import ./openapi_client
import ./sqlite_adapter
import ./static_assets
import ./seed_commands
import ./durable_jobs

proc cliArguments(arguments: openArray[string]): seq[string] =
  ## Copy borrowed command arguments before they cross a frontend boundary.
  for argument in arguments:
    result.add(argument)

proc runDatabaseCli*(app: Application, arguments: openArray[string]): int =
  ## Execute the migration or seed command using app-owned registries. SQLite
  ## remains the safe default, while an explicit provider owns another backend
  ## and its close policy; the CLI never infers credentials or DSNs.
  if app.isNil or app.migrationRegistry.isNil:
    raise newException(ValueError, "Application migration registry is required")
  if arguments.len < 1 or arguments.len > 2:
    raise newException(ValueError,
      "db command must be: db status|migrate|up|rollback|seed [sqlite-path]")
  var commandArgs = @[arguments[0]]
  let path = if arguments.len == 2: arguments[1] else: app.migrationDatabasePath
  if path.strip().len == 0:
    raise newException(ValueError, "Migration database location cannot be empty")
  let migrations = app.migrationRegistry.loadMigrations()
  if arguments[0].toLowerAscii() == "seed":
    if app.seedRegistry.isNil:
      raise newException(ValueError, "Application seed registry is required")
    var adapter: DatabaseAdapter
    var closeAdapter: proc(adapter: DatabaseAdapter) {.gcsafe.}
    if not app.migrationDatabaseProvider.open.isNil:
      adapter = app.migrationDatabaseProvider.open(path)
      closeAdapter = app.migrationDatabaseProvider.close
    else:
      adapter = newSqliteDatabaseAdapter(path)
      closeAdapter = proc(adapter: DatabaseAdapter) {.gcsafe.} =
        cast[SqliteDatabaseAdapter](adapter).close()
    if adapter.isNil:
      raise newException(ValueError, "Migration database provider returned nil")
    defer: closeAdapter(adapter)
    for name in app.seedRegistry.runSeeds(adapter):
      echo "seeded " & name
    return 0
  let command = parseMigrationCommand(commandArgs)
  if not app.migrationDatabaseProvider.runMigrations.isNil:
    let outcome = app.migrationDatabaseProvider.runMigrations(path, migrations, command)
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
    return 0
  let adapter = newSqliteDatabaseAdapter(path)
  defer: adapter.close()
  if adapter.dialect != dialectSqlite:
    raise newException(ValueError,
      "Migration adapter must provide runMigrations for non-SQLite backends")
  let outcome = executeMigrationCommand(
    cast[SqliteDatabaseAdapter](adapter), migrations, command)
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

proc runJobsCli*(app: Application, arguments: openArray[string]): int =
  ## Run only explicit durable-job lifecycle operations. The CLI never loads
  ## code from a persisted kind; handlers must already be registered by the
  ## application, preserving the same trust boundary as HTTP workers.
  if app.isNil or app.durableJobStore.isNil or app.durableJobRegistry.isNil:
    raise newException(ValueError,
      "Application durable job store and registry are required")
  if arguments.len < 1 or arguments.len > 2:
    raise newException(ValueError,
      "jobs command must be: jobs run [max]|recover")
  case arguments[0].toLowerAscii()
  of "recover":
    app.durableJobStore.recoverProcessing()
    echo "recovered durable jobs"
  of "run":
    let maxJobs = if arguments.len == 2: parseInt(arguments[1]) else: 1
    if maxJobs < 1:
      raise newException(ValueError, "jobs run max must be positive")
    var processed = 0
    while processed < maxJobs:
      let outcome = waitFor app.durableJobRegistry.runNext(
        app.durableJobStore, app.jobs)
      if not outcome.processed:
        if processed == 0:
          echo "no pending durable jobs"
        break
      inc processed
      if outcome.succeeded:
        echo "completed " & outcome.id
      else:
        stderr.writeLine("failed " & outcome.id & ": " & outcome.error)
        return 1
  else:
    raise newException(ValueError, "unknown jobs command: " & arguments[0])
  0

proc runOpenApiCli*(app: Application, arguments: openArray[string]): int =
  ## Generate a document from the application's already-registered HTTP routes.
  ## The collector intentionally emits empty schemas for plain routes; typed
  ## routes remain authoritative when an application uses addDocumentedRoute.
  ## An optional path makes this command usable in CI artifact generation while
  ## stdout remains convenient for local inspection and shell pipelines.
  if app.isNil:
    raise newException(ValueError, "Application is required")
  if arguments.len > 1:
    raise newException(ValueError, "openapi command accepts at most one output path")
  let registry = newOpenApiRegistry("Mahanaim API", "0.1.0")
  discard registry.collectRoutes(app.router)
  let output = $registry.document()
  if arguments.len == 1:
    if arguments[0].strip().len == 0:
      raise newException(ValueError, "OpenAPI output path cannot be empty")
    writeFile(arguments[0], output & "\n")
  else:
    echo output
  0

proc runOpenApiTypeScriptCli*(app: Application,
                              arguments: openArray[string]): int =
  ## Emit the deterministic TypeScript projection separately from the JSON
  ## document command so CI can publish both artifacts without shell parsing.
  if app.isNil:
    raise newException(ValueError, "Application is required")
  if arguments.len > 1:
    raise newException(ValueError,
      "openapi-ts command accepts at most one output path")
  let registry = newOpenApiRegistry("Mahanaim API", "0.1.0")
  discard registry.collectRoutes(app.router)
  let output = registry.typescriptClient()
  if arguments.len == 1:
    if arguments[0].strip().len == 0:
      raise newException(ValueError, "TypeScript output path cannot be empty")
    writeFile(arguments[0], output)
  else:
    echo output
  0

proc runAdminCli*(app: Application, arguments: openArray[string]): int =
  ## Keep administrative mutations behind an explicitly configured callback.
  ## A password is intentionally read from MAHANAIM_ADMIN_PASSWORD rather than
  ## command-line arguments, because process listings commonly expose argv.
  if app.isNil or app.adminUserCreator.isNil:
    raise newException(ValueError,
      "Application admin user creator is required")
  if arguments.len < 2 or arguments.len > 3 or
      arguments[0].toLowerAscii() != "create-user":
    raise newException(ValueError,
      "admin command must be: admin create-user <identifier> [subject]")
  let identifier = arguments[1].strip()
  if identifier.len == 0:
    raise newException(ValueError, "Admin user identifier cannot be empty")
  let password = getEnv("MAHANAIM_ADMIN_PASSWORD")
  if password.len == 0:
    raise newException(ValueError,
      "MAHANAIM_ADMIN_PASSWORD must be set for admin create-user")
  let subject = if arguments.len == 3 and arguments[2].strip().len > 0:
    arguments[2].strip()
  else:
    identifier
  let createdSubject = app.adminUserCreator(identifier, password, subject)
  if createdSubject.strip().len == 0:
    raise newException(ValueError, "Admin user creator returned an empty subject")
  echo "created admin user " & identifier
  0

proc runStaticCli*(app: Application, arguments: openArray[string]): int =
  ## Parse only the frontend flags here; file traversal and copy policy remain
  ## in static_assets so embedding and standalone callers share one contract.
  discard app
  if arguments.len < 2 or arguments[0].toLowerAscii() != "collect":
    raise newException(ValueError,
      "static command must be: static collect <source...> --output <path>")
  var sources: seq[string] = @[]
  var output = ""
  var overwrite = false
  var index = 1
  while index < arguments.len:
    case arguments[index].toLowerAscii()
    of "--output", "-o":
      inc index
      if index >= arguments.len or arguments[index].strip().len == 0:
        raise newException(ValueError, "static collect output path is required")
      output = arguments[index]
    of "--overwrite":
      overwrite = true
    else:
      sources.add(arguments[index])
    inc index
  if sources.len == 0 or output.strip().len == 0:
    raise newException(ValueError,
      "static command must be: static collect <source...> --output <path>")
  let policy = newStaticCollectionPolicy(sources, output, overwrite)
  let assets = collectStaticAssets(policy)
  for asset in assets:
    echo "collected " & asset.relativePath
  echo "collected " & $assets.len & " static files"
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
    echo "  db seed [sqlite-path]  Run application seed providers"
    echo "  jobs run [max]|recover Run or recover durable jobs"
    echo "  openapi [PATH]  Generate an OpenAPI document from registered routes"
    echo "  openapi-ts [PATH]  Generate a TypeScript client from registered routes"
    echo "  admin create-user <identifier> [subject]  Create an admin user"
    echo "  static collect <source...> --output <path>  Collect static assets"
    echo "  check  Run application pre-flight checks"
    for name, definition in app.commands:
      echo "  " & name & "  " & definition.description
    return 0
  case copied[0].toLowerAscii()
  of "check":
    if copied.len != 1:
      raise newException(ValueError, "check command does not accept arguments")
    ## Keep the embedding frontend on the same pure report contract as the
    ## standalone executable, so CI and host applications cannot drift apart.
    let report = checkApplication(app)
    for issue in report.issues:
      let severity = if issue.severity == checkError: "ERROR" else: "WARN"
      echo severity & " [" & issue.code & "] " & issue.message
    if report.passed: 0 else: 1
  of "db":
    if copied.len == 1:
      raise newException(ValueError,
        "db command must be: db status|up|rollback|seed [sqlite-path]")
    return runDatabaseCli(app, copied[1 .. ^1])
  of "jobs":
    if copied.len == 1:
      raise newException(ValueError,
        "jobs command must be: jobs run [max]|recover")
    return runJobsCli(app, copied[1 .. ^1])
  of "openapi":
    return runOpenApiCli(app, copied[1 .. ^1])
  of "openapi-ts":
    return runOpenApiTypeScriptCli(app, copied[1 .. ^1])
  of "admin":
    if copied.len == 1:
      raise newException(ValueError,
        "admin command must be: admin create-user <identifier> [subject]")
    return runAdminCli(app, copied[1 .. ^1])
  of "static":
    if copied.len == 1:
      raise newException(ValueError,
        "static command must be: static collect <source...> --output <path>")
    return runStaticCli(app, copied[1 .. ^1])
  else:
    if app.commands.hasKey(copied[0]):
      return app.runCommand(copied[0], copied[1 .. ^1])
    raise newException(ValueError, "Unknown command: " & copied[0])

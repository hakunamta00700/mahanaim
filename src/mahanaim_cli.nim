## Minimal CLI for the first P0 slice.
##
## The command reports the framework-owned surface. Mutating commands require an
## embedding application to configure their explicit persistence callback, so
## the frontend cannot silently invent an account or database connection.

import std/[os, osproc, strutils]
import mahanaim/[application, checks, cli, config, generator]

proc printUsage() =
  echo "mahanaim <command>"
  echo "  new NAME [PATH]  Generate a new project"
  echo "  db status|migrate|up|rollback [PATH]  Run application migrations"
  echo "  jobs run [max]|recover  Run or recover durable jobs"
  echo "  openapi [PATH]  Generate an OpenAPI document from registered routes"
  echo "  admin create-user <identifier> [subject]  Create an admin user"
  echo "  static collect <source...> --output <path>  Collect static assets"
  echo "  dev      Load configuration and validate the app"
  echo "  test     Run the test suite through Nimble"
  echo "  check    Validate configuration and framework contracts"

proc printCheckReport(report: CheckReport): bool =
  ## Keep human-readable output in the CLI while the report remains reusable by
  ## CI integrations and embedding applications.
  for issue in report.issues:
    let severity = if issue.severity == checkError: "ERROR" else: "WARN"
    let line = severity & " [" & issue.code & "] " & issue.message
    if issue.severity == checkError:
      stderr.writeLine(line)
    else:
      echo line
  if report.passed:
    echo "Mahanaim framework checks passed"
    return true
  stderr.writeLine("Mahanaim framework checks failed")
  false

proc main() =
  let command = if paramCount() == 0: "help" else: paramStr(1).toLowerAscii()
  case command
  of "new":
    if paramCount() < 2 or paramCount() > 3:
      stderr.writeLine("Usage: mahanaim new NAME [PATH]")
      quit(1)
    let name = paramStr(2)
    let root = if paramCount() == 3: paramStr(3) else: name
    generateProject(ProjectSpec(name: name, root: root))
    echo "Generated Mahanaim project: ", root
  of "dev":
    let config = loadConfig()
    let report = checkApplication(newApplication(config))
    if not printCheckReport(report):
      quit(1)
    echo "Mahanaim development configuration loaded: ", config.host, ":", config.port
  of "check":
    let config = loadConfig()
    let report = checkApplication(newApplication(config))
    if not printCheckReport(report):
      quit(1)
  of "test":
    # Delegate to the package's canonical test task so CLI and CI execute the
    # same suite instead of maintaining two subtly different test paths.
    let (output, exitCode) = execCmdEx("nimble test")
    stdout.write(output)
    if exitCode != 0:
      quit(exitCode)
  of "db":
    var arguments: seq[string] = @[]
    if paramCount() >= 2:
      for index in 2 .. paramCount():
        arguments.add(paramStr(index))
    try:
      quit(runCli(newApplication(), @["db"] & arguments))
    except CatchableError as error:
      stderr.writeLine(error.msg)
      quit(1)
  of "jobs":
    var arguments: seq[string] = @[]
    if paramCount() >= 2:
      for index in 2 .. paramCount():
        arguments.add(paramStr(index))
    try:
      quit(runCli(newApplication(), @["jobs"] & arguments))
    except CatchableError as error:
      stderr.writeLine(error.msg)
      quit(1)
  of "openapi":
    var arguments: seq[string] = @[]
    if paramCount() >= 2:
      for index in 2 .. paramCount():
        arguments.add(paramStr(index))
    try:
      quit(runCli(newApplication(), @["openapi"] & arguments))
    except CatchableError as error:
      stderr.writeLine(error.msg)
      quit(1)
  of "admin":
    var arguments: seq[string] = @[]
    if paramCount() >= 2:
      for index in 2 .. paramCount():
        arguments.add(paramStr(index))
    try:
      quit(runCli(newApplication(), @["admin"] & arguments))
    except CatchableError as error:
      stderr.writeLine(error.msg)
      quit(1)
  of "static":
    var arguments: seq[string] = @[]
    if paramCount() >= 2:
      for index in 2 .. paramCount():
        arguments.add(paramStr(index))
    try:
      quit(runCli(newApplication(), @["static"] & arguments))
    except CatchableError as error:
      stderr.writeLine(error.msg)
      quit(1)
  of "help", "--help", "-h":
    printUsage()
  else:
    stderr.writeLine("Unknown command: " & command)
    printUsage()
    quit(1)

when isMainModule:
  main()

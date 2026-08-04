## Minimal CLI for the first P0 slice.
##
## The command intentionally reports the supported surface instead of pretending
## that database/admin commands already exist. Each future command can be added
## without changing the Application API.

import std/[os, osproc, strutils]
import mahanaim/[application, checks, cli, config, generator]

proc printUsage() =
  echo "mahanaim <command>"
  echo "  new NAME [PATH]  Generate a new project"
  echo "  db status|up|rollback [PATH]  Run application migrations"
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
  of "help", "--help", "-h":
    printUsage()
  else:
    stderr.writeLine("Unknown command: " & command)
    printUsage()
    quit(1)

when isMainModule:
  main()

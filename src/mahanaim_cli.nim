## Minimal CLI for the first P0 slice.
##
## The command intentionally reports the supported surface instead of pretending
## that database/admin commands already exist. Each future command can be added
## without changing the Application API.

import std/[os, osproc, strutils]
import mahanaim/[application, generator]

proc printUsage() =
  echo "mahanaim <command>"
  echo "  new NAME [PATH]  Generate a new project"
  echo "  dev      Load configuration and validate the app"
  echo "  test     Run the test suite through Nimble"
  echo "  check    Validate configuration and framework contracts"

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
    echo "Mahanaim development configuration loaded: ", config.host, ":", config.port
  of "check":
    discard loadConfig()
    echo "Mahanaim configuration check passed"
  of "test":
    # Delegate to the package's canonical test task so CLI and CI execute the
    # same suite instead of maintaining two subtly different test paths.
    let (output, exitCode) = execCmdEx("nimble test")
    stdout.write(output)
    if exitCode != 0:
      quit(exitCode)
  of "help", "--help", "-h":
    printUsage()
  else:
    stderr.writeLine("Unknown command: " & command)
    printUsage()
    quit(1)

when isMainModule:
  main()

## Minimal CLI for the first P0 slice.
##
## The command intentionally reports the supported surface instead of pretending
## that database/admin commands already exist. Each future command can be added
## without changing the Application API.

import std/[os, strutils]
import mahanaim/application

proc printUsage() =
  echo "mahanaim <command>"
  echo "  new      Describe project generation (coming next)"
  echo "  dev      Load configuration and validate the app"
  echo "  test     Run the test suite through Nimble"
  echo "  check    Validate configuration and framework contracts"

proc main() =
  let command = if paramCount() == 0: "help" else: paramStr(1).toLowerAscii()
  case command
  of "dev":
    let config = loadConfig()
    echo "Mahanaim development configuration loaded: ", config.host, ":", config.port
  of "check":
    discard loadConfig()
    echo "Mahanaim configuration check passed"
  of "new", "test", "help", "--help", "-h":
    printUsage()
  else:
    stderr.writeLine("Unknown command: " & command)
    printUsage()
    quit(1)

when isMainModule:
  main()

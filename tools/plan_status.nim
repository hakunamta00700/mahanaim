## Print a machine-checked summary of the repository implementation plan.
##
## This is intentionally a small CLI boundary around release_checks: the
## checker owns marker syntax and counting, while this executable owns only
## command-line input and human-readable output. It can therefore be used by
## maintainers, CI logs, or a release dashboard without coupling planning to
## the application runtime.

import std/os
import mahanaim/release_checks

proc main() =
  let planPath = if commandLineParams().len > 0:
    commandLineParams()[0]
  else:
    getCurrentDir() / "plan.md"
  let issues = validatePlanChecklist(planPath)
  if issues.len > 0:
    for issue in issues:
      stderr.writeLine(issue)
    quit(1)
  let summary = summarizePlanChecklist(planPath)
  echo "plan=" & planPath &
    " completed=" & $summary.completed &
    " partial=" & $summary.partial &
    " pending=" & $summary.pending

when isMainModule:
  main()

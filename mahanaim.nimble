# Mahanaim framework package manifest.
# Keep the first slice dependency-light so the core contracts are easy to audit.
import std/[os, strutils]

version       = "0.1.0"
author        = "Mahanaim contributors"
description   = "A low-magic full-stack web framework for Nim"
license       = "MIT"
srcDir        = "src"
bin           = @[
  "mahanaim_cli"
]

requires "nim >= 2.2.0"
requires "nimcrypto >= 0.7.3"
requires "prologue >= 0.6.8"
requires "taskpools >= 0.1.0"

proc dependencyPathArgs(): string =
  ## Tasks are run by Nimble but invoke Nim directly, so pass every locked
  ## package path explicitly instead of depending on an ambient compiler path.
  let packageNames = "nimcrypto prologue taskpools cookiejar httpx ioselectors " &
    "wepoll logue cligen regex unicodedb"
  let paths = staticExec("nimble path " & packageNames)
  for path in paths.splitLines:
    let normalized = path.strip()
    if normalized.len > 0:
      result.add(" --path:" & quoteShell(normalized))

task test, "Run the framework test suite":
  exec "nim c --path:src" & dependencyPathArgs() & " -r tests/test_core.nim"

task check, "Compile the framework CLI":
  exec "nimble build"

task verify, "Compile the CLI and validate package contracts":
  exec "nimble build"

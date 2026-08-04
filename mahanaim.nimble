# Mahanaim framework package manifest.
# Keep the first slice dependency-light so the core contracts are easy to audit.
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

task test, "Run the framework test suite":
  exec "nim c --path:src -r tests/test_core.nim"

task check, "Compile the framework CLI":
  exec "nimble build"

task verify, "Compile the CLI and validate package contracts":
  exec "nimble build"

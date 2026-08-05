## Package lockfile contract used by local verification and CI.
##
## This test deliberately checks only metadata shape and required package
## presence. Nimble remains responsible for fetching packages; the framework
## gate prevents an incomplete or tampered lockfile from reaching that step.

import std/[os, unittest]
import mahanaim

const requiredPackages = [
  "nimcrypto", "parsetoml", "prologue", "taskpools", "db_connector",
  "argon2", "checksums", "timezones"
]

suite "dependency lock contracts":
  test "repository lockfile contains required package metadata":
    let issues = validateDependencyLock(getCurrentDir() / "nimble.lock",
      requiredPackages)
    check issues.len == 0

## Release and runtime compatibility checks.
##
## Dependency lockfiles protect package inputs, while release artifacts need a
## separate integrity gate. This module keeps both checks as pure, reusable
## contracts so CI, a release script, and an embedding CLI can share them.

import std/[os, strutils]
import nimcrypto

type
  NimVersionSpec* = object
    major*: int
    minor*: int
    patch*: int

  RuntimeSupportMatrix* = object
    minimumNim*: NimVersionSpec
    operatingSystems*: seq[string]

  ReleaseArtifact* = object
    path*: string
    sha256*: string

proc currentOperatingSystem*(): string =
  ## Normalize compiler target names so the matrix is stable across CI tools.
  when defined(windows): "windows"
  elif defined(macosx): "macos"
  elif defined(linux): "linux"
  else: "other"

proc currentNimVersion*(): NimVersionSpec =
  ## Nim exposes these as compile-time constants; no shell or network lookup is
  ## needed, which keeps release checks deterministic in offline CI.
  NimVersionSpec(major: NimMajor, minor: NimMinor, patch: NimPatch)

proc compareVersion(left, right: NimVersionSpec): int =
  if left.major != right.major: return cmp(left.major, right.major)
  if left.minor != right.minor: return cmp(left.minor, right.minor)
  cmp(left.patch, right.patch)

proc validateRuntimeSupport*(matrix: RuntimeSupportMatrix): seq[string] =
  ## Return all issues at once so a matrix mistake does not hide a target
  ## mismatch discovered later in the same CI run.
  if matrix.operatingSystems.len == 0:
    result.add("runtime matrix must list at least one operating system")
  if matrix.minimumNim.major < 0 or matrix.minimumNim.minor < 0 or
      matrix.minimumNim.patch < 0:
    result.add("runtime matrix minimum Nim version must not be negative")
  let current = currentNimVersion()
  if compareVersion(current, matrix.minimumNim) < 0:
    result.add("current Nim version is below the supported minimum")
  if currentOperatingSystem() notin matrix.operatingSystems:
    result.add("current operating system is not in the supported matrix")

proc validSha256(value: string): bool =
  if value.len != 64:
    return false
  for character in value:
    if character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc sha256File*(path: string): string =
  ## Read bytes unchanged; text normalization would invalidate release hashes
  ## on Windows and make the same artifact produce different checksums.
  if path.strip().len == 0 or not fileExists(path):
    raise newException(ValueError, "Release artifact does not exist: " & path)
  $sha256.digest(readFile(path))

proc verifyArtifactChecksum*(artifact: ReleaseArtifact): bool =
  ## Invalid metadata fails closed rather than being treated as an absent hash.
  if not validSha256(artifact.sha256):
    return false
  try:
    sha256File(artifact.path).toLowerAscii() == artifact.sha256.toLowerAscii()
  except ValueError:
    false

proc validateReleaseArtifacts*(artifacts: openArray[ReleaseArtifact]): seq[string] =
  ## Produce machine-readable paths for all missing or tampered artifacts.
  for artifact in artifacts:
    if artifact.path.strip().len == 0:
      result.add("artifact path is empty")
    elif not verifyArtifactChecksum(artifact):
      result.add("artifact checksum mismatch: " & artifact.path)

## Release and runtime compatibility checks.
##
## Dependency lockfiles protect package inputs, while release artifacts need a
## separate integrity gate. This module keeps both checks as pure, reusable
## contracts so CI, a release script, and an embedding CLI can share them.

import std/[json, os, strutils]
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

proc validHex(value: string, expectedLength: int): bool =
  ## Lockfile digests are metadata, not secrets; validate their shape before
  ## a package manager consumes the file so malformed locks fail closed.
  if value.len != expectedLength:
    return false
  for character in value:
    if character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc validateDependencyLock*(path: string,
                             requiredPackages: openArray[string]): seq[string] =
  ## Validate the stable Nimble lockfile contract without shelling out or
  ## resolving network dependencies. The package manager remains responsible
  ## for installation; this reusable check catches drift before compilation.
  if path.strip().len == 0 or not fileExists(path):
    return @["dependency lockfile does not exist: " & path]
  var root: JsonNode
  try:
    root = parseFile(path)
  except CatchableError as error:
    return @["dependency lockfile is not valid JSON: " & error.msg]
  if root.kind != JObject:
    result.add("dependency lockfile root must be an object")
    return
  if not root.hasKey("version") or root["version"].kind != JInt or
     root["version"].getInt() != 2:
    result.add("dependency lockfile version must be 2")
  if not root.hasKey("packages") or root["packages"].kind != JObject:
    result.add("dependency lockfile packages must be an object")
    return
  let packages = root["packages"]
  for packageName, packageValue in packages.pairs:
    if packageValue.kind != JObject:
      result.add("dependency package must be an object: " & packageName)
      continue
    if not packageValue.hasKey("version") or
       packageValue["version"].kind != JString or
       packageValue["version"].getStr().strip().len == 0:
      result.add("dependency package version is missing: " & packageName)
    if not packageValue.hasKey("url") or packageValue["url"].kind != JString or
       packageValue["url"].getStr().strip().len == 0:
      result.add("dependency package url is missing: " & packageName)
    if not packageValue.hasKey("downloadMethod") or
       packageValue["downloadMethod"].kind != JString or
       packageValue["downloadMethod"].getStr().strip().len == 0:
      result.add("dependency package download method is missing: " & packageName)
    if not packageValue.hasKey("checksums") or
       packageValue["checksums"].kind != JObject or
       not packageValue["checksums"].hasKey("sha1") or
       packageValue["checksums"]["sha1"].kind != JString or
       not validHex(packageValue["checksums"]["sha1"].getStr(), 40):
      result.add("dependency package sha1 checksum is invalid: " & packageName)
  for packageName in requiredPackages:
    if packageName.strip().len == 0:
      result.add("required dependency package name is empty")
    elif not packages.hasKey(packageName):
      result.add("required dependency package is missing: " & packageName)

proc validateDefinitionOfDone*(path: string): seq[string] =
  ## Validate the release checklist as a small, repository-owned document
  ## contract. The validator intentionally checks structure and evidence
  ## vocabulary only; it never marks an implementation complete on behalf of
  ## a maintainer. This keeps prose review and engineering evidence separate.
  if path.strip().len == 0 or not fileExists(path):
    return @[
      "definition of done document does not exist: " & path
    ]
  let document = readFile(path)
  let requiredSections = [
    "## 기능 단위 체크리스트",
    "## 검증 게이트",
    "## 상태 표기 규칙"
  ]
  for section in requiredSections:
    if section notin document:
      result.add("definition of done section is missing: " & section)

  ## A checklist marker is deliberately narrow. A typo such as `[X]` would
  ## otherwise look complete in rendered Markdown while escaping the status
  ## convention used by plan.md.
  for line in document.splitLines:
    let marker = line.strip()
    if marker.startsWith("- ["):
      if marker.len < 5 or marker[4] != ']' or
          marker[3] notin {' ', '-', 'x'}:
        result.add("definition of done checkbox marker is invalid: " & marker)

  let requiredCommands = [
    "nimble test", "nimble check", "nimble verify", "nimble docsCheck",
    "git diff --check"
  ]
  for command in requiredCommands:
    if command notin document:
      result.add("definition of done verification command is missing: " &
        command)

## Release and runtime compatibility checks.
##
## Dependency lockfiles protect package inputs, while release artifacts need a
## separate integrity gate. This module keeps both checks as pure, reusable
## contracts so CI, a release script, and an embedding CLI can share them.

import std/[algorithm, json, os, strutils]
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

proc renderArtifactManifest*(artifacts: openArray[ReleaseArtifact]): string =
  ## Render a stable, line-oriented manifest that shell tooling and release
  ## jobs can consume without parsing JSON or recomputing a glob order. The
  ## manifest records supplied checksums only; callers should run
  ## `validateReleaseArtifacts` first when the artifact files are available.
  ## Keeping rendering separate from verification lets CI generate a manifest
  ## before publishing while deployment gates can verify it independently.
  var ordered: seq[ReleaseArtifact] = @[]
  for artifact in artifacts:
    if artifact.path.strip().len == 0 or artifact.path.contains({'\r', '\n', '\0'}):
      raise newException(ValueError, "Release artifact path is invalid")
    if not validSha256(artifact.sha256):
      raise newException(ValueError,
        "Release artifact SHA-256 is invalid: " & artifact.path)
    ordered.add(artifact)
  ordered.sort(proc(left, right: ReleaseArtifact): int =
    cmp(left.path, right.path))
  for artifact in ordered:
    result.add("path=" & artifact.path & "\n")
    result.add("sha256=" & artifact.sha256.toLowerAscii() & "\n")

proc writeArtifactManifest*(path: string,
                           artifacts: openArray[ReleaseArtifact]) =
  ## File I/O remains a thin shell around the pure renderer so tests and
  ## embedding applications can use the same validation and byte format.
  if path.strip().len == 0 or path.contains({'\r', '\n', '\0'}):
    raise newException(ValueError, "Release manifest path is invalid")
  writeFile(path, renderArtifactManifest(artifacts))

proc collectReleaseArtifacts*(paths: openArray[string]): seq[ReleaseArtifact] =
  ## Convert actual files into manifest metadata in one framework-owned step.
  ## Release scripts should provide only the artifact paths; checksum encoding,
  ## duplicate rejection, and deterministic ordering remain shared across
  ## Linux, Windows, macOS, and embedding applications.
  if paths.len == 0:
    raise newException(ValueError, "At least one release artifact is required")
  for path in paths:
    if path.strip().len == 0 or path.contains({'\r', '\n', '\0'}):
      raise newException(ValueError, "Release artifact path is invalid")
    if not fileExists(path):
      raise newException(ValueError, "Release artifact does not exist: " & path)
    for existing in result:
      if existing.path == path:
        raise newException(ValueError, "Duplicate release artifact: " & path)
    result.add(ReleaseArtifact(path: path, sha256: sha256File(path)))
  result.sort(proc(left, right: ReleaseArtifact): int =
    cmp(left.path, right.path))

proc writeArtifactManifestForFiles*(manifestPath: string,
                                    paths: openArray[string]) =
  ## Keep file discovery and manifest output composable: callers can inspect
  ## the collected metadata, while the convenience API handles the common
  ## release-runner path without duplicating checksum logic.
  writeArtifactManifest(manifestPath, collectReleaseArtifacts(paths))

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

## Deterministic local static asset collection.
##
## Collection is intentionally separate from HTTP serving: the command scans
## trusted source directories, validates the complete copy plan, and only then
## writes the deployable tree. This keeps filesystem policy testable without a
## server adapter and prevents a partially parsed CLI option from changing the
## destination boundary.

import std/[algorithm, os, strutils, tables]

type
  StaticCollectionError* = object of CatchableError
    ## User/configuration errors are distinguishable from generic CLI failures.

  StaticCollectionPolicy* = object
    ## Source order is meaningful for diagnostics, while duplicate relative
    ## paths are always rejected instead of silently depending on that order.
    sourceDirectories*: seq[string]
    outputDirectory*: string
    overwriteExisting*: bool

  StaticAsset* = object
    ## A manifest entry makes the result inspectable by CLI, tests, and future
    ## manifest/checksum integrations without exposing mutable internal state.
    relativePath*: string
    sourcePath*: string
    destinationPath*: string
    size*: int64

proc normalizedAbsolutePath(path: string): string =
  ## Windows path comparison is case-insensitive; normalizing separators gives
  ## the same containment rule on every supported host.
  result = absolutePath(path).replace('\\', '/').toLowerAscii()
  while result.len > 1 and result.endsWith('/'):
    result.setLen(result.len - 1)

proc pathWithin(parent, candidate: string): bool =
  let normalizedParent = normalizedAbsolutePath(parent)
  let normalizedCandidate = normalizedAbsolutePath(candidate)
  normalizedCandidate == normalizedParent or
    normalizedCandidate.startsWith(normalizedParent & "/")

proc normalizeRelativePath(path: string): string =
  ## `relativePath` is trusted only after this explicit check. The guard keeps
  ## future path implementations from turning an asset name into traversal.
  result = path.replace('\\', '/')
  while result.startsWith("./"):
    result = result[2 .. ^1]
  if result.len == 0 or result == ".." or result.startsWith("../") or
      result.startsWith('/') or result.contains(":"):
    raise newException(StaticCollectionError,
      "Static asset path escapes its source directory")

proc newStaticCollectionPolicy*(sourceDirectories: openArray[string],
                                outputDirectory: string,
                                overwriteExisting = false):
                                StaticCollectionPolicy =
  ## Validate source/output topology before any directory is created. In
  ## particular, writing into a source tree would make a second collection
  ## observe its own generated files and is therefore rejected.
  if sourceDirectories.len == 0:
    raise newException(StaticCollectionError,
      "At least one static source directory is required")
  if outputDirectory.strip().len == 0:
    raise newException(StaticCollectionError,
      "Static output directory is required")
  result.outputDirectory = absolutePath(outputDirectory)
  result.overwriteExisting = overwriteExisting
  for source in sourceDirectories:
    if source.strip().len == 0:
      raise newException(StaticCollectionError,
        "Static source directory cannot be empty")
    let sourcePath = absolutePath(source)
    if not dirExists(sourcePath):
      raise newException(StaticCollectionError,
        "Static source directory does not exist: " & source)
    let sourceInfo = getFileInfo(sourcePath, followSymlink = false)
    if sourceInfo.kind != pcDir:
      raise newException(StaticCollectionError,
        "Static source must be a real directory: " & source)
    if pathWithin(sourcePath, result.outputDirectory):
      raise newException(StaticCollectionError,
        "Static output directory cannot be inside a source directory")
    result.sourceDirectories.add(sourcePath)
  if fileExists(result.outputDirectory):
    raise newException(StaticCollectionError,
      "Static output path is a file: " & result.outputDirectory)
  if dirExists(result.outputDirectory) and
      getFileInfo(result.outputDirectory, followSymlink = false).kind != pcDir:
    raise newException(StaticCollectionError,
      "Static output directory must not be a symbolic link")

proc collectStaticAssets*(policy: StaticCollectionPolicy): seq[StaticAsset] =
  ## Build and validate a complete manifest before copying any file. This
  ## ensures duplicate paths and overwrite conflicts fail atomically at the
  ## framework boundary, while individual copy failures remain filesystem
  ## errors visible to the caller.
  if policy.sourceDirectories.len == 0 or
      policy.outputDirectory.strip().len == 0:
    raise newException(StaticCollectionError,
      "Static collection policy is incomplete")
  var seen = initTable[string, string]()
  for source in policy.sourceDirectories:
    for path in walkDirRec(source, {pcFile, pcLinkToFile}, {pcDir}, relative = false,
                                        checkDir = true, skipSpecial = true):
      let info = getFileInfo(path, followSymlink = false)
      if info.kind != pcFile:
        raise newException(StaticCollectionError,
          "Static source contains a non-regular file: " & path)
      let relative = normalizeRelativePath(relativePath(path, source))
      let collisionKey = relative.toLowerAscii()
      if seen.hasKey(collisionKey):
        raise newException(StaticCollectionError,
          "Duplicate static asset path: " & relative)
      seen[collisionKey] = path
      result.add(StaticAsset(relativePath: relative, sourcePath: path,
        destinationPath: policy.outputDirectory / relative, size: int64(info.size)))
  result.sort(proc(left, right: StaticAsset): int =
    cmp(left.relativePath, right.relativePath))
  for asset in result:
    if fileExists(asset.destinationPath) and not policy.overwriteExisting:
      raise newException(StaticCollectionError,
        "Static asset already exists: " & asset.relativePath)
  if result.len > 0 and not dirExists(policy.outputDirectory):
    createDir(policy.outputDirectory)
  for asset in result:
    let parent = splitFile(asset.destinationPath).dir
    if parent.len > 0 and not dirExists(parent):
      createDir(parent)
    copyFile(asset.sourcePath, asset.destinationPath)

## Build a release manifest from files using the framework-owned checksum API.
##
## The tool intentionally accepts a semicolon-separated path list through an
## environment variable. This keeps the invocation identical on PowerShell,
## Bash, and GitHub Actions while avoiding shell-specific checksum formatting.

import std/[os, strutils]
import mahanaim

let manifestPath = getEnv("MAHANAIM_RELEASE_MANIFEST")
let artifactList = getEnv("MAHANAIM_RELEASE_ARTIFACTS")
if manifestPath.strip().len == 0 or artifactList.strip().len == 0:
  stderr.writeLine("MAHANAIM_RELEASE_MANIFEST and MAHANAIM_RELEASE_ARTIFACTS are required")
  quit(2)

var paths: seq[string] = @[]
for path in artifactList.split(';'):
  if path.strip().len > 0:
    paths.add(path)

try:
  writeArtifactManifestForFiles(manifestPath, paths)
  echo "release manifest written: " & manifestPath
except CatchableError as error:
  stderr.writeLine("release manifest failed: " & error.msg)
  quit(1)

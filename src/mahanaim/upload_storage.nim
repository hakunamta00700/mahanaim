## Framework-neutral upload validation and local storage.
##
## Multipart parsing deliberately stops at BodyPart. This module owns the
## security-sensitive next step, so adapters can use the same filename, size,
## MIME, and overwrite policy without importing Prologue or a web server type.

import std/[os, strutils]
import ./body_parser

type
  UploadPolicy* = object
    ## The storage root must be outside the public web root in deployment.
    rootDirectory*: string
    maxBytes*: int
    allowedContentTypes*: seq[string]
    overwriteExisting*: bool

  UploadValidationError* = object of CatchableError
    ## Callers can distinguish rejected user input from filesystem failures.

  StoredUpload* = object
    ## Keep both user-visible metadata and the actual path explicit.
    fieldName*: string
    originalFilename*: string
    contentType*: string
    path*: string
    size*: int

proc newUploadPolicy*(rootDirectory: string, maxBytes = 10 * 1024 * 1024,
                      allowedContentTypes: seq[string] = @[],
                      overwriteExisting = false): UploadPolicy =
  ## Normalize policy values once; content-type comparison is case-insensitive.
  result.rootDirectory = rootDirectory
  result.maxBytes = maxBytes
  result.allowedContentTypes = @[]
  for contentType in allowedContentTypes:
    result.allowedContentTypes.add(contentType.strip().toLowerAscii())
  result.overwriteExisting = overwriteExisting

proc safeFilename(filename: string): bool =
  ## A stored name is a single leaf, never a caller-controlled path.
  if filename.len == 0 or filename in [".", ".."] or filename.isAbsolute():
    return false
  for character in filename:
    if character in {'/', '\\', '\0'}:
      return false
  true

proc validateUpload*(part: BodyPart, policy: UploadPolicy) =
  ## Validate before touching the filesystem so rejected uploads leave no file.
  if policy.rootDirectory.strip().len == 0:
    raise newException(UploadValidationError, "Upload root directory is empty")
  if policy.maxBytes < 0:
    raise newException(UploadValidationError, "Upload maxBytes must not be negative")
  if not safeFilename(part.filename):
    raise newException(UploadValidationError, "Unsafe upload filename")
  if part.content.len > policy.maxBytes:
    raise newException(UploadValidationError, "Upload exceeds configured size limit")
  if policy.allowedContentTypes.len > 0 and
     part.contentType.toLowerAscii() notin policy.allowedContentTypes:
    raise newException(UploadValidationError, "Upload content type is not allowed")

proc saveUpload*(part: BodyPart, policy: UploadPolicy,
                 storedFilename = ""): StoredUpload =
  ## Save only after validation, and never overwrite an existing file unless
  ## the policy explicitly opts in to that operational behavior.
  validateUpload(part, policy)
  let filename = if storedFilename.len == 0: part.filename else: storedFilename
  if not safeFilename(filename):
    raise newException(UploadValidationError, "Unsafe stored upload filename")
  if not dirExists(policy.rootDirectory):
    createDir(policy.rootDirectory)
  let destination = policy.rootDirectory / filename
  if fileExists(destination) and not policy.overwriteExisting:
    raise newException(UploadValidationError, "Upload destination already exists")
  writeFile(destination, part.content)
  StoredUpload(fieldName: part.name, originalFilename: part.filename,
    contentType: part.contentType, path: destination, size: part.content.len)

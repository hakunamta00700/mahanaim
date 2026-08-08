## Executable local storage, static collection, and cache TTL example.
##
## This is intentionally provider-free: it proves only the local framework
## contracts. S3/CDN/Redis production configuration belongs to application
## deployment documentation and its own live evidence.

import std/[options, os]
import mahanaim

let root = getTempDir() / "mahanaim_local_storage_example"
if dirExists(root):
  removeDir(root)

let staticSource = root / "assets"
let staticOutput = root / "public"
createDir(staticSource)
writeFile(staticSource / "app.css", "body { color: green; }\n")

try:
  let uploads = newUploadPolicy(root / "uploads",
    webRootDirectory = staticOutput,
    maxBytes = 1024,
    allowedContentTypes = @["text/plain"],
    allowedExtensions = @[".txt"])
  let stored = saveUpload(BodyPart(name: "attachment", filename: "note.txt",
    contentType: "text/plain", content: "local upload\n"), uploads)
  doAssert readFile(stored.path) == "local upload\n"

  let assets = collectStaticAssets(newStaticCollectionPolicy(@[staticSource],
    staticOutput))
  doAssert assets.len == 1
  doAssert readFile(staticOutput / "app.css") == "body { color: green; }\n"

  let cache = newInMemoryCacheStore()
  cache.set("examples/local", "cached", ttlSeconds = 60)
  doAssert cache.get("examples/local") == some("cached")
  echo "local-storage-ok"
finally:
  if dirExists(root):
    removeDir(root)

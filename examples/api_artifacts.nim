## Executable OpenAPI JSON and generated TypeScript client example.

import std/[asyncdispatch, httpcore, json, os, strutils]
import mahanaim

let root = getTempDir() / "mahanaim_api_artifacts_example"
if dirExists(root):
  removeDir(root)
createDir(root)

let openApiPath = root / "openapi.json"
let clientPath = root / "client.ts"
try:
  let app = newApplication()
  proc product(request: Request): Future[Response] {.async, gcsafe.} =
    discard request
    return jsonResponse("{\"name\":\"example\"}", Http200)
  app.get("/products/:id<int>", "products.get", product)

  doAssert app.runCli(["openapi", openApiPath]) == 0
  let document = parseJson(readFile(openApiPath))
  doAssert document["openapi"].getStr() == "3.1.0"
  doAssert document["paths"].hasKey("/products/{id}")

  doAssert app.runCli(["openapi-ts", clientPath]) == 0
  let client = readFile(clientPath)
  doAssert client.contains("export class ApiClient")
  doAssert client.contains("async products_get")
  echo "api-artifacts-ok"
finally:
  if dirExists(root):
    removeDir(root)

## Compile contract for the public `mahanaim` package entry point.
##
## Runtime semantics belong to test_core and the adapter contract suites. This
## file stays compile-only and checks representative API families so an export
## removal or signature drift fails before a downstream application discovers
## it.

import mahanaim

static:
  ## Core request/response and application lifecycle surface.
  doAssert compiles(newApplication())
  doAssert compiles(newRequest("GET", "/health"))
  doAssert compiles(textResponse("ok"))
  doAssert compiles(jsonResponse("{}"))

  ## Routing, metadata, validation, and serialization families.
  doAssert compiles(initRouter())
  doAssert compiles(newModelMetadata("Item", "items"))
  doAssert compiles(newModelField("name", modelString))
  doAssert compiles(defaultSerializationPolicy())
  doAssert compiles(stringField("name", flQuery))

  ## Database, storage, cache, template, and testing boundaries.
  doAssert compiles(newSqliteDatabaseAdapter())
  doAssert compiles(newQuerySet("items"))
  doAssert compiles(newInMemoryObjectStorage())
  doAssert compiles(newInMemoryCacheStore())
  doAssert compiles(newTemplateEngine())
  doAssert compiles(newTemplateRenderContext())
  doAssert compiles(newTestClient(newApplication()))

  ## Extension and operational surfaces remain public contracts too.
  doAssert compiles(newThreadPoolExecutor())
  doAssert compiles(defaultSecurityPolicy())
  doAssert compiles(Controller())

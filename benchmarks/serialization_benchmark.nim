## Deterministic metadata serialization benchmark.
##
## The workload measures the framework-owned metadata-to-JSON boundary only.
## It validates sensitive-field exclusion and JSON-name projection on every
## iteration so a fast but unsafe serializer cannot appear successful.

import std/[json, monotimes, strutils, tables, times]
import mahanaim/[models, serialization]

const
  SerializationCount = 10_000

proc benchmarkMetadata(): ModelMetadata =
  ## Build metadata once, matching application startup behavior rather than
  ## charging schema construction to every request serialization.
  result = newModelMetadata("BenchmarkAccount", "benchmark_accounts")
  result.addField(newModelField("id", modelInteger, primaryKey = true))
  result.addField(newModelField("display_name", modelString,
    jsonName = "displayName"))
  result.addField(newModelField("email", modelString))
  result.addField(newModelField("password_hash", modelString,
    sensitive = true, nullable = true))

proc benchmarkValues(index: int): Table[string, JsonNode] =
  ## Values are request/result-shaped data; the sensitive value must never
  ## cross the default response boundary even when it is present in the row.
  result = initTable[string, JsonNode]()
  result["id"] = newJInt(index.int64)
  result["display_name"] = newJString("user-" & $index)
  result["email"] = newJString("user-" & $index & "@example.test")
  result["password_hash"] = newJString("never-return-this")

proc main() =
  let metadata = benchmarkMetadata()
  var serialized = 0
  var projectedFields = 0
  let started = getMonoTime()
  for index in 0 ..< SerializationCount:
    let document = serializeModel(metadata, benchmarkValues(index))
    doAssert document.valid
    doAssert document.document["displayName"].kind == JString
    doAssert document.document["displayName"].getStr() == "user-" & $index
    doAssert not document.document.hasKey("password_hash")
    doAssert not document.json().contains("never-return-this")
    inc serialized
    inc projectedFields, document.document.len
  let elapsed = getMonoTime() - started

  ## Keep the output stable enough for artifact comparison without imposing a
  ## machine-specific latency threshold on correctness CI.
  doAssert serialized == SerializationCount
  doAssert projectedFields == SerializationCount * 3
  echo "serializations=" & $serialized &
    " projected_fields=" & $projectedFields &
    " elapsed_ms=" & $elapsed.inMilliseconds

when isMainModule:
  main()

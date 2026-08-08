## Executable SQLite CRUD and migration tutorial.
##
## The matching guide explains each boundary. This program keeps the complete
## metadata -> migration -> repository CRUD -> rollback path runnable without
## a server, credentials, or a persistent database file.

import std/[json, options, tables]
import mahanaim

proc main() =
  let adapter = newSqliteDatabaseAdapter()
  defer: adapter.close()

  var items = createModelMetadata("Item", "items")
  items.addField(newModelField("id", modelInteger, primaryKey = true))
  items.addField(newModelField("title", modelString))
  let migration = migrationFromMetadata(items, "001_items")
  let applied = executeMigrationCommand(adapter, @[migration],
    parseMigrationCommand(["migrate"]))
  doAssert applied.applied == @["001_items"]

  let repository = newDatabaseRepository(items, adapter)
  var first = initTable[string, JsonNode]()
  first["id"] = newJInt(1)
  first["title"] = newJString("Write tutorial")
  doAssert repository.create(first)["title"].getStr() == "Write tutorial"

  var patch = initTable[string, JsonNode]()
  patch["title"] = newJString("Ship tutorial")
  let updated = repository.update("1", patch)
  doAssert updated.isSome
  doAssert updated.get()["title"].getStr() == "Ship tutorial"
  doAssert repository.list(SelectQuery()).len == 1
  doAssert repository.delete("1")
  doAssert repository.find("1").isNone

  let rolledBack = executeMigrationCommand(adapter, @[migration],
    parseMigrationCommand(["rollback"]))
  doAssert rolledBack.rolledBack.isSome
  doAssert rolledBack.rolledBack.get() == "001_items"
  echo "sqlite-crud-migration-ok"

when isMainModule:
  main()

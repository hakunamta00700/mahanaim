## Metadata-driven database repository.
##
## The repository translates ResourceRow values into the backend-neutral
## DatabaseAdapter contract. It intentionally does not own HTTP behavior;
## resources.nim can attach this store to the existing CRUD route convention
## once request/session wiring is ready.

import std/[json, options, strutils, tables]
import ./database
import ./models
import ./resources

type
  DatabaseRepository* = ref object
    metadata*: ModelMetadata
    adapter*: DatabaseAdapter
    idField*: string

proc newDatabaseRepository*(metadata: ModelMetadata,
                            adapter: DatabaseAdapter): DatabaseRepository =
  ## Keep repository construction explicit so a connection cannot be hidden in
  ## global state or accidentally shared across request lifecycles.
  if adapter.isNil:
    raise newException(ValueError, "Database repository requires an adapter")
  new(result)
  result.metadata = metadata
  result.adapter = adapter
  result.idField = "id"
  for field in metadata.fields:
    if field.primaryKey:
      result.idField = field.name
      break

proc fieldFor(repository: DatabaseRepository, name: string): Option[ModelField] =
  for field in repository.metadata.fields:
    if field.name == name or field.columnName == name or field.jsonName == name:
      return some(field)
  none(ModelField)

proc identifier(value: string): string =
  ## Repository-generated identifiers are still validated at this boundary;
  ## values from a request are never treated as raw SQL fragments.
  if value.len == 0:
    raise newException(ValueError, "Repository identifier cannot be empty")
  for character in value:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      raise newException(ValueError, "Unsafe repository identifier: " & value)
  "\"" & value & "\""

proc sqlValue(value: JsonNode): SqlValue =
  ## JSON is the transport type at the CRUD boundary; nested values are kept
  ## as canonical JSON text until a typed custom adapter is introduced.
  case value.kind
  of JNull: nullValue()
  of JString: textValue(value.getStr())
  of JInt: integerValue(value.getInt())
  of JFloat: floatValue(value.getFloat())
  of JBool: booleanValue(value.getBool())
  of JObject, JArray: textValue($value)

proc jsonValue(field: ModelField, value: SqlValue): JsonNode =
  if value.kind == sqlNull:
    return newJNull()
  case field.kind
  of modelInteger:
    try: newJInt(parseInt(value.text))
    except ValueError: newJString(value.text)
  of modelFloat:
    try: newJFloat(parseFloat(value.text))
    except ValueError: newJString(value.text)
  of modelBoolean:
    newJBool(value.text.toLowerAscii() in ["1", "true", "t", "yes"])
  of modelJson:
    try: parseJson(value.text)
    except CatchableError: newJString(value.text)
  else: newJString(value.text)

proc columns(repository: DatabaseRepository): seq[string] =
  for field in repository.metadata.fields:
    result.add(field.columnName)

proc rowFromValues(repository: DatabaseRepository,
                   values: seq[SqlValue]): ResourceRow =
  let fields = repository.metadata.fields
  for index, field in fields:
    if index < values.len:
      result[field.name] = jsonValue(field, values[index])

proc selectQuery(repository: DatabaseRepository,
                 query: SelectQuery): CompiledQuery =
  var normalized = query
  normalized.table = repository.metadata.tableName
  if normalized.columns.len == 0:
    normalized.columns = repository.columns()
  else:
    for index, name in normalized.columns:
      let field = repository.fieldFor(name)
      if field.isNone:
        raise newException(ValueError, "Unknown repository field: " & name)
      normalized.columns[index] = field.get().columnName
  for filter in normalized.filters.mitems:
    let field = repository.fieldFor(filter.field)
    if field.isNone:
      raise newException(ValueError, "Unknown repository filter: " & filter.field)
    filter.field = field.get().columnName
  for order in normalized.orderBy.mitems:
    let field = repository.fieldFor(order.field)
    if field.isNone:
      raise newException(ValueError, "Unknown repository order: " & order.field)
    order.field = field.get().columnName
  compileSelect(normalized, repository.adapter.dialect)

proc list*(repository: DatabaseRepository,
           query = SelectQuery()): seq[ResourceRow] =
  ## List uses the shared compiler, including pagination and bound filters.
  let compiled = repository.selectQuery(query)
  for values in repository.adapter.execute(compiled):
    result.add(repository.rowFromValues(values))

proc idFilter(repository: DatabaseRepository, id: string): QueryFilter =
  let field = repository.fieldFor(repository.idField)
  if field.isNone:
    raise newException(ValueError, "Repository primary key field is missing")
  var value = textValue(id)
  if field.get().kind == modelInteger:
    try: value = integerValue(parseInt(id).int64)
    except ValueError: raise newException(ValueError, "Invalid integer repository id")
  QueryFilter(field: repository.idField, operator: filterEqual, value: value)

proc find*(repository: DatabaseRepository, id: string): Option[ResourceRow] =
  var query = SelectQuery(filters: @[repository.idFilter(id)], limit: 1)
  let rows = repository.list(query)
  if rows.len > 0: some(rows[0]) else: none(ResourceRow)

proc rowId(repository: DatabaseRepository, row: ResourceRow): Option[JsonNode] =
  if row.hasKey(repository.idField): some(row[repository.idField])
  else: none(JsonNode)

proc create*(repository: DatabaseRepository, row: ResourceRow): ResourceRow =
  ## Insert fields in metadata order for deterministic SQL and parameter order.
  var names: seq[string] = @[]
  var values: seq[SqlValue] = @[]
  for field in repository.metadata.fields:
    if row.hasKey(field.name):
      names.add(field.columnName)
      values.add(sqlValue(row[field.name]))
  if names.len == 0:
    raise newException(ValueError, "Repository create requires at least one field")
  var placeholders: seq[string] = @[]
  for index in 0 ..< values.len:
    placeholders.add(if repository.adapter.dialect == dialectPostgres:
      "$" & $(index + 1) else: "?")
  var sql = "INSERT INTO " & identifier(repository.metadata.tableName) & " ("
  var quoted: seq[string] = @[]
  for name in names: quoted.add(identifier(name))
  sql.add(quoted.join(", ") & ") VALUES (" & placeholders.join(", ") & ")")
  discard repository.adapter.execute(CompiledQuery(sql: sql, parameters: values))
  let id = repository.rowId(row)
  if id.isSome:
    let found = repository.find($id.get())
    if found.isSome: return found.get()
  row

proc update*(repository: DatabaseRepository, id: string,
             row: ResourceRow): Option[ResourceRow] =
  if repository.find(id).isNone:
    return none(ResourceRow)
  var assignments: seq[string] = @[]
  var values: seq[SqlValue] = @[]
  for field in repository.metadata.fields:
    if field.name != repository.idField and row.hasKey(field.name):
      assignments.add(identifier(field.columnName) & " = " &
        (if repository.adapter.dialect == dialectPostgres:
          "$" & $(values.len + 1) else: "?"))
      values.add(sqlValue(row[field.name]))
  if assignments.len == 0:
    return repository.find(id)
  let idParameter = repository.idFilter(id).value
  values.add(idParameter)
  let idPlaceholder = if repository.adapter.dialect == dialectPostgres:
    "$" & $values.len else: "?"
  let sql = "UPDATE " & identifier(repository.metadata.tableName) & " SET " &
    assignments.join(", ") & " WHERE " & identifier(
      repository.fieldFor(repository.idField).get().columnName) & " = " & idPlaceholder
  discard repository.adapter.execute(CompiledQuery(sql: sql, parameters: values))
  repository.find(id)

proc delete*(repository: DatabaseRepository, id: string): bool =
  if repository.find(id).isNone:
    return false
  let field = repository.fieldFor(repository.idField).get()
  let placeholder = if repository.adapter.dialect == dialectPostgres: "$1" else: "?"
  discard repository.adapter.execute(CompiledQuery(
    sql: "DELETE FROM " & identifier(repository.metadata.tableName) &
      " WHERE " & identifier(field.columnName) & " = " & placeholder,
    parameters: @[repository.idFilter(id).value]))
  true

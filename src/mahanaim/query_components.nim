## Reusable query-string to database-query component.
##
## HTTP adapters expose strings, while database adapters require typed bound
## values. This module owns that translation and validation so resources,
## admin pages, and future controllers share one safe pagination/filter/sort/
## field-selection contract without concatenating user input into SQL.

import std/[json, options, strutils, tables, times]
import ./core
import ./database
import ./models
import ./security
import ./validation

type
  QueryComponentOptions* = object
    defaultPage*: int
    defaultPageSize*: int
    maxPageSize*: int
    ## Cursor pagination is opt-in because a model must provide a stable,
    ## uniquely ordered field. Empty means the component rejects `cursor`
    ## rather than guessing a potentially unstable ordering.
    cursorField*: string
    ## Signing is opt-in and must be supplied by the application owner; the
    ## parser never invents a deployment secret.
    cursorSecret*: string
    cursorTtlSeconds*: int64
    ## Tests and deterministic callers may inject a clock. Zero uses wall time.
    cursorNow*: int64

  CursorPagination* = object
    ## The cursor is translated into a bound comparison; it never becomes SQL.
    field*: string
    value*: SqlValue
    descending*: bool

  QueryComponentResult* = object
    query*: SelectQuery
    pagination*: Pagination
    cursor*: Option[CursorPagination]
    ## Total counting is opt-in because it can require a second query and must
    ## never become an accidental cost for ordinary list endpoints.
    includeTotal*: bool
    errors*: seq[ValidationIssue]

proc defaultQueryComponentOptions*(): QueryComponentOptions =
  ## Conservative defaults bound query cost before a backend sees the request.
  QueryComponentOptions(defaultPage: 1, defaultPageSize: 20,
    maxPageSize: 100, cursorField: "", cursorSecret: "",
    cursorTtlSeconds: 0, cursorNow: 0)

proc addQueryIssue(result: var QueryComponentResult, field, code, message: string) =
  ## Reuse the framework validation envelope so query errors have the same
  ## location/code shape as path, header, form, and body errors.
  result.errors.add(ValidationIssue(field: field, location: "query",
    code: code, message: message))

proc parsePositive(parsed: var QueryComponentResult, values: Table[string, string],
                   name: string, fallback: int): int =
  if not values.hasKey(name):
    return fallback
  try:
    parseInt(values[name])
  except ValueError:
    parsed.addQueryIssue(name, "invalid_integer", "Query value must be an integer")
    fallback

proc parseBoolean(parsed: var QueryComponentResult,
                  values: Table[string, string], name: string): bool =
  ## Keep boolean query syntax deliberately small and predictable across
  ## adapters; invalid input is reported through the common validation shape.
  if not values.hasKey(name):
    return false
  let normalized = values[name].toLowerAscii()
  if normalized notin ["true", "false", "1", "0"]:
    parsed.addQueryIssue(name, "invalid_boolean", "Query value must be a boolean")
    return false
  normalized in ["true", "1"]

proc encodeCursor*(value: SqlValue, secret = "", ttlSeconds: int64 = 0,
                   now: int64 = 0): string {.gcsafe.} =
  ## Cursor tokens are opaque at the HTTP boundary but retain the neutral SQL
  ## type so a decoded value can be bound without string interpolation.
  let payload = case value.kind
    of sqlText: "s:" & value.text
    of sqlInteger: "i:" & $value.integer
    of sqlFloat: "f:" & $value.floating
    of sqlBoolean: "b:" & (if value.boolean: "1" else: "0")
    of sqlNull: raise newException(ValueError, "Null values cannot be cursors")
  ## Hex encoding avoids delimiters and external codec state, which also keeps
  ## this parser safe to call from the framework's gcsafe async route boundary.
  const digits = "0123456789abcdef"
  var encoded = ""
  for character in payload:
    let value = ord(character)
    encoded.add(digits[value shr 4])
    encoded.add(digits[value and 0x0f])
  if secret.len == 0:
    return "m1." & encoded
  if ttlSeconds < 0:
    raise newException(ValueError, "Cursor TTL cannot be negative")
  let issuedAt = if now > 0: now else: getTime().toUnix()
  let expiresAt = if ttlSeconds > 0: issuedAt + ttlSeconds else: 0
  let unsigned = "m2." & $expiresAt & "." & encoded
  signValue(secret, unsigned)

proc decodeCursorPayload(encoded: string): Option[SqlValue] {.gcsafe.} =
  ## Decode the typed payload after token envelope/signature checks are done.
  if encoded.len == 0 or encoded.len mod 2 != 0:
    return none(SqlValue)
  proc hexValue(character: char): int {.gcsafe.} =
    if character in {'0'..'9'}: ord(character) - ord('0')
    elif character in {'a'..'f'}: ord(character) - ord('a') + 10
    elif character in {'A'..'F'}: ord(character) - ord('A') + 10
    else: -1
  var payload = ""
  var index = 0
  while index < encoded.len:
    let high = hexValue(encoded[index])
    let low = hexValue(encoded[index + 1])
    if high < 0 or low < 0:
      return none(SqlValue)
    payload.add(char((high shl 4) or low))
    inc index, 2
  if payload.len < 3 or payload[1] != ':':
    return none(SqlValue)
  try:
    case payload[0]
    of 's': some(textValue(payload[2 .. ^1]))
    of 'i': some(integerValue(parseInt(payload[2 .. ^1]).int64))
    of 'f': some(floatValue(parseFloat(payload[2 .. ^1])))
    of 'b':
      if payload[2 .. ^1] notin ["0", "1"]: none(SqlValue)
      else: some(booleanValue(payload[2 .. ^1] == "1"))
    else: none(SqlValue)
  except CatchableError:
    none(SqlValue)

proc decodeCursor*(token: string, secret = "", now: int64 = 0): Option[SqlValue] {.gcsafe.} =
  ## Decode only the framework-owned token format. Legacy raw values are
  ## intentionally handled by typedValue for backwards compatibility.
  if token.startsWith("m1."):
    return decodeCursorPayload(token[3 .. ^1])
  if not token.startsWith("m2.") or secret.len == 0:
    return none(SqlValue)
  let parts = token.split('.')
  if parts.len != 4:
    return none(SqlValue)
  let unsigned = parts[0] & "." & parts[1] & "." & parts[2]
  let verified = verifySignedValue(secret, unsigned & "." & parts[3])
  if verified.isNone:
    return none(SqlValue)
  try:
    let expiresAt = parseInt(parts[1]).int64
    if expiresAt > 0:
      let current = if now > 0: now else: getTime().toUnix()
      if current >= expiresAt:
        return none(SqlValue)
  except ValueError:
    return none(SqlValue)
  decodeCursorPayload(parts[2])

proc typedValue(field: ModelField, raw: string,
                parsed: var QueryComponentResult, key: string): SqlValue {.gcsafe.}

proc cursorValue(field: ModelField, raw: string,
                 parsed: var QueryComponentResult, key: string,
                 secret = "", now: int64 = 0): SqlValue {.gcsafe.} =
  ## Prefer an encoded cursor, then accept the original typed raw form.
  if raw.startsWith("m1.") or raw.startsWith("m2."):
    let decoded = decodeCursor(raw, secret, now)
    if decoded.isNone:
      parsed.addQueryIssue(key, "invalid_cursor", "Cursor token is invalid")
      return nullValue()
    let expected = case field.kind
      of modelInteger: sqlInteger
      of modelFloat: sqlFloat
      of modelBoolean: sqlBoolean
      else: sqlText
    if decoded.get().kind != expected:
      parsed.addQueryIssue(key, "invalid_cursor_type",
        "Cursor token type does not match the cursor field")
      return nullValue()
    return decoded.get()
  typedValue(field, raw, parsed, key)

proc cursorTokenFor*(field: ModelField, value: JsonNode,
                     secret = "", ttlSeconds: int64 = 0,
                     now: int64 = 0): string =
  ## Convert a serialized row value back to the field's typed cursor token.
  let typed = case field.kind
    of modelInteger: integerValue(value.getInt().int64)
    of modelFloat:
      if value.kind == JInt: floatValue(value.getInt().float)
      else: floatValue(value.getFloat())
    of modelBoolean: booleanValue(value.getBool())
    else: textValue(if value.kind == JString: value.getStr() else: $value)
  encodeCursor(typed, secret, ttlSeconds, now)

proc findField(fields: openArray[ModelField], name: string): Option[ModelField] =
  ## Accept Nim, database, and JSON names while returning one canonical field.
  for field in fields:
    if field.name == name or field.columnName == name or field.jsonName == name:
      return some(field)
  none(ModelField)

proc typedValue(field: ModelField, raw: string,
                parsed: var QueryComponentResult, key: string): SqlValue {.gcsafe.} =
  ## Convert query text to a bound SqlValue according to model metadata.
  case field.kind
  of modelInteger:
    try: integerValue(parseInt(raw).int64)
    except ValueError:
      parsed.addQueryIssue(key, "invalid_integer", "Filter value must be an integer")
      nullValue()
  of modelFloat:
    try: floatValue(parseFloat(raw))
    except ValueError:
      parsed.addQueryIssue(key, "invalid_float", "Filter value must be a number")
      nullValue()
  of modelBoolean:
    let normalized = raw.toLowerAscii()
    if normalized notin ["true", "false", "1", "0"]:
      parsed.addQueryIssue(key, "invalid_boolean", "Filter value must be a boolean")
      return nullValue()
    booleanValue(normalized in ["true", "1"])
  of modelString, modelDateTime, modelUuid, modelFile, modelJson, modelReference:
    textValue(raw)

proc parseOperator(raw: string, operator: var FilterOperator): bool =
  ## Double-underscore suffixes make filter intent explicit and extensible.
  case raw
  of "eq": operator = filterEqual
  of "ne": operator = filterNotEqual
  of "gt": operator = filterGreater
  of "gte": operator = filterGreaterOrEqual
  of "lt": operator = filterLess
  of "lte": operator = filterLessOrEqual
  of "like": operator = filterLike
  of "isnull": operator = filterIsNull
  of "notnull": operator = filterIsNotNull
  else: return false
  true

proc parseQueryComponent*(request: Request,
                          fields: openArray[ModelField],
                          options = defaultQueryComponentOptions()): QueryComponentResult =
  ## Parse supported query controls and leave unrelated application parameters
  ## untouched. Callers must check `valid` before executing the query.
  if options.defaultPage < 1 or options.defaultPageSize < 1 or
     options.maxPageSize < 1 or options.defaultPageSize > options.maxPageSize:
    raise newException(ValueError, "Invalid query component pagination defaults")
  result.query = SelectQuery(filters: @[], orderBy: @[], columns: @[])
  result.includeTotal = parseBoolean(result, request.query, "include_total")
  let page = result.parsePositive(request.query, "page", options.defaultPage)
  let pageSize = result.parsePositive(request.query, "page_size",
    options.defaultPageSize)
  try:
    result.pagination = newPagination(page, pageSize, options.maxPageSize)
    result.query = result.query.withPagination(result.pagination)
  except ValueError as error:
    result.addQueryIssue("page", "invalid_pagination", error.msg)

  if request.query.hasKey("fields"):
    for rawName in request.query["fields"].split(','):
      let name = rawName.strip()
      let field = findField(fields, name)
      if name.len == 0: continue
      if field.isNone:
        result.addQueryIssue("fields", "unknown_field", "Unknown selected field: " & name)
      elif field.get().name notin result.query.columns:
        result.query.columns.add(field.get().name)

  if request.query.hasKey("sort"):
    for rawSort in request.query["sort"].split(','):
      var name = rawSort.strip()
      var descending = false
      if name.startsWith("-"):
        descending = true
        if name.len == 1:
          result.addQueryIssue("sort", "invalid_field", "Sort field must not be empty")
          continue
        name = name[1 .. ^1]
      let field = findField(fields, name)
      if field.isNone:
        result.addQueryIssue("sort", "unknown_field", "Unknown sort field: " & name)
      else:
        result.query.orderBy.add(QueryOrder(field: field.get().name,
          descending: descending))

  if request.query.hasKey("cursor"):
    ## Offset and cursor semantics must not be combined: doing so would make
    ## the starting row ambiguous and could silently skip records.
    if request.query.hasKey("page"):
      result.addQueryIssue("cursor", "conflicting_pagination",
        "Cursor pagination cannot be combined with page")
    if options.cursorField.strip().len == 0:
      result.addQueryIssue("cursor", "cursor_field_required",
        "Cursor pagination requires an explicitly configured cursor field")
    else:
      let cursorField = findField(fields, options.cursorField)
      if cursorField.isNone:
        result.addQueryIssue("cursor", "unknown_cursor_field",
          "Unknown cursor field: " & options.cursorField)
      else:
        let canonical = cursorField.get().name
        var descending = false
        var ordered = false
        for order in result.query.orderBy:
          if order.field == canonical:
            descending = order.descending
            ordered = true
            break
        if not ordered:
          ## A cursor without an explicit matching order gets one stable
          ## default; callers can still request descending with `sort=-field`.
          result.query.orderBy.add(QueryOrder(field: canonical,
            descending: false))
        result.cursor = some(CursorPagination(field: canonical,
          value: cursorValue(cursorField.get(), request.query["cursor"],
            result, "cursor", options.cursorSecret, options.cursorNow),
          descending: descending))
        result.query.filters.add(QueryFilter(field: canonical,
          operator: if descending: filterLess else: filterGreater,
          value: result.cursor.get().value))

  for key, rawValue in request.query:
    if not key.startsWith("filter."):
      continue
    if key.len <= 7:
      result.addQueryIssue(key, "invalid_filter", "Filter field must not be empty")
      continue
    let expression = key[7 .. ^1]
    let parts = expression.split("__", maxsplit = 1)
    let field = findField(fields, parts[0])
    if field.isNone:
      result.addQueryIssue(key, "unknown_field", "Unknown filter field: " & parts[0])
      continue
    var operator = filterEqual
    if parts.len > 1 and not parseOperator(parts[1], operator):
      result.addQueryIssue(key, "unknown_operator", "Unknown filter operator: " & parts[1])
      continue
    let value = if operator in {filterIsNull, filterIsNotNull}:
      nullValue() else: typedValue(field.get(), rawValue, result, key)
    result.query.filters.add(QueryFilter(field: field.get().name,
      operator: operator, value: value))

proc valid*(queryResult: QueryComponentResult): bool =
  ## Invalid query input must never reach a repository or SQL compiler.
  queryResult.errors.len == 0

## Configuration providers and secret-safe rendering.
##
## Providers are intentionally small and composable. `.env` is useful for
## local development, JSON/TOML are explicit deployment inputs, and process
## environment variables always win over file values.

import std/[json, os, strutils, tables]
import parsetoml

const defaultRequestTimeoutMs* = 30_000

type
  AppConfig* = object
    ## Runtime settings plus a separate secret store.
    environment*: string
    debug*: bool
    host*: string
    port*: int
    requestTimeoutMs*: int
    executorMaxConcurrentJobs*: int
    ## Bounds jobs waiting for a saturated synchronous executor. Zero keeps
    ## the existing unbounded admission compatibility mode.
    executorMaxQueuedJobs*: int
    secrets*: Table[string, string]
    ## Non-scalar settings remain typed JSON so arrays, dates, and nested
    ## deployment settings are not flattened into lossy strings.
    values*: Table[string, JsonNode]

proc newConfig(environment, host: string, debug: bool, port: int): AppConfig =
  ## A finite default prevents an accidentally stalled request from owning a
  ## connection forever. Set zero explicitly when an application has a
  ## deliberate long-running request contract.
  result = AppConfig(environment: environment, debug: debug, host: host,
    port: port, requestTimeoutMs: defaultRequestTimeoutMs,
    executorMaxConcurrentJobs: 0, executorMaxQueuedJobs: 0)
  result.secrets = initTable[string, string]()
  result.values = initTable[string, JsonNode]()

proc defaultConfig*(): AppConfig =
  ## Safe development defaults; production loaders override these values.
  newConfig("development", "127.0.0.1", true, 8000)

proc stripQuotes(value: string): string =
  let trimmed = value.strip()
  if trimmed.len >= 2 and
     ((trimmed[0] == '"' and trimmed[^1] == '"') or
      (trimmed[0] == '\'' and trimmed[^1] == '\'')):
    return trimmed[1 .. ^2]
  trimmed

proc parseBool(value, source: string): bool =
  case stripQuotes(value).toLowerAscii()
  of "1", "true", "yes", "on": true
  of "0", "false", "no", "off": false
  else: raise newException(ValueError, "invalid boolean in " & source)

proc loadDotEnv*(path: string): Table[string, string] =
  ## Parse KEY=VALUE lines without logging any value.
  result = initTable[string, string]()
  if not fileExists(path):
    return
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let separator = trimmed.find('=')
    if separator <= 0:
      continue
    let key = trimmed[0 ..< separator].strip()
    result[key] = stripQuotes(trimmed[separator + 1 .. ^1])

proc applyValue(config: var AppConfig, key, value, source: string) =
  ## One mapping function keeps all providers semantically consistent.
  let normalized = key.strip().toLowerAscii()
  case normalized
  of "environment", "mahanaim_env": config.environment = stripQuotes(value)
  of "debug", "mahanaim_debug": config.debug = parseBool(value, source)
  of "host", "mahanaim_host": config.host = stripQuotes(value)
  of "port", "mahanaim_port":
    try:
      config.port = parseInt(stripQuotes(value))
    except ValueError:
      raise newException(ValueError, "invalid port in " & source)
  of "request_timeout_ms", "mahanaim_request_timeout_ms":
    try:
      config.requestTimeoutMs = parseInt(stripQuotes(value))
    except ValueError:
      raise newException(ValueError, "invalid request timeout in " & source)
  of "executor_max_concurrent_jobs", "mahanaim_executor_max_concurrent_jobs":
    try:
      config.executorMaxConcurrentJobs = parseInt(stripQuotes(value))
    except ValueError:
      raise newException(ValueError, "invalid executor capacity in " & source)
  of "executor_max_queued_jobs", "mahanaim_executor_max_queued_jobs":
    try:
      config.executorMaxQueuedJobs = parseInt(stripQuotes(value))
    except ValueError:
      raise newException(ValueError, "invalid executor queue capacity in " & source)
  else:
    let secretKey = if normalized.startsWith("secret."): normalized[7 .. ^1]
                    elif normalized.startsWith("secrets."): normalized[8 .. ^1]
                    elif normalized.startsWith("secret_"): normalized[7 .. ^1]
                    else: ""
    if secretKey.len > 0:
      config.secrets[secretKey] = stripQuotes(value)

proc applyValues(config: var AppConfig, values: Table[string, string], source: string) =
  for key, value in values:
    config.applyValue(key, value, source)

proc isSecretKey(key: string): bool =
  let normalized = key.toLowerAscii()
  normalized.startsWith("secret.") or normalized.startsWith("secrets.") or
  normalized.startsWith("secret_")

proc isSupportedTomlKey(key: string): bool

proc validateJsonConfigType(key: string, value: JsonNode, source: string) =
  ## Validate framework-owned scalar types before string conversion. Unknown
  ## extension values intentionally remain typed JSON in AppConfig.values.
  let normalized = key.toLowerAscii()
  case normalized
  of "environment", "mahanaim_env", "host", "mahanaim_host":
    if value.kind != JString:
      raise newException(ValueError,
        key & " must be a string in " & source)
  of "debug", "mahanaim_debug":
    if value.kind != JBool:
      raise newException(ValueError,
        key & " must be a boolean in " & source)
  of "port", "mahanaim_port", "request_timeout_ms",
     "mahanaim_request_timeout_ms", "executor_max_concurrent_jobs",
     "mahanaim_executor_max_concurrent_jobs", "executor_max_queued_jobs",
     "mahanaim_executor_max_queued_jobs":
    if value.kind != JInt:
      raise newException(ValueError,
        key & " must be an integer in " & source)

proc validateTomlConfigType(key: string, value: TomlValueRef, source: string) =
  ## TOML has native scalar kinds, so preserve them through schema validation
  ## rather than accepting a quoted number that only looks numeric later.
  let normalized = key.toLowerAscii()
  let expected = case normalized
    of "environment", "mahanaim_env", "host", "mahanaim_host": "string"
    of "debug", "mahanaim_debug": "boolean"
    of "port", "mahanaim_port", "request_timeout_ms",
       "mahanaim_request_timeout_ms", "executor_max_concurrent_jobs",
       "mahanaim_executor_max_concurrent_jobs", "executor_max_queued_jobs",
       "mahanaim_executor_max_queued_jobs": "integer"
    else: ""
  if expected.len == 0:
    return
  let matches = case expected
    of "string": value.kind == TomlValueKind.String
    of "boolean": value.kind == TomlValueKind.Bool
    of "integer": value.kind == TomlValueKind.Int
    else: false
  if not matches:
    raise newException(ValueError,
      key & " must be a TOML " & expected & " in " & source)

proc applyStructuredValues(config: var AppConfig,
                           values: Table[string, JsonNode], source: string) =
  ## Structured values use the same secret boundary as scalar providers.
  for key, value in values:
    if key.toLowerAscii() == "secrets":
      if value.kind != JObject:
        raise newException(ValueError, "secrets must be an object in " & source)
      for secretKey, secretValue in value.pairs:
        if secretValue.kind notin {JString, JInt, JFloat, JBool}:
          raise newException(ValueError,
            "structured secret value is not supported: " & secretKey)
        config.secrets[secretKey.toLowerAscii()] =
          if secretValue.kind == JString: secretValue.getStr() else: $secretValue
      continue
    if isSecretKey(key):
      raise newException(ValueError,
        "structured secret value is not supported in " & source)
    validateJsonConfigType(key, value, source)
    if value.kind in {JString, JInt, JFloat, JBool} and
       isSupportedTomlKey(key):
      let scalar = if value.kind == JString: value.getStr() else: $value
      config.applyValue(key, scalar, source)
    else:
      config.values[key.toLowerAscii()] = value

proc loadJsonConfig*(path: string): Table[string, string] =
  ## Flatten supported JSON settings into the common provider representation.
  result = initTable[string, string]()
  let root = json.parseFile(path)
  if root.kind != JObject:
    raise newException(ValueError, "JSON config root must be an object")
  for key, value in root.pairs:
    if key == "secrets" and value.kind == JObject:
      for secretKey, secretValue in value.pairs:
        result["secret." & secretKey] =
          if secretValue.kind == JString: secretValue.getStr() else: $secretValue
    elif value.kind in {JString, JInt, JFloat, JBool}:
      validateJsonConfigType(key, value, path)
      result[key] = if value.kind == JString: value.getStr() else: $value

proc loadJsonStructuredConfig*(path: string): Table[string, JsonNode] =
  ## Preserve non-scalar root values for the typed AppConfig extension store.
  result = initTable[string, JsonNode]()
  let root = json.parseFile(path)
  if root.kind != JObject:
    raise newException(ValueError, "JSON config root must be an object")
  for key, value in root.pairs:
    validateJsonConfigType(key, value, path)
    if value.kind in {JArray, JObject}:
      result[key] = value

proc twoDigits(value: int): string =
  if value < 10: "0" & $value else: $value

proc tomlDateText(value: TomlValueRef): string =
  case value.kind
  of TomlValueKind.Date:
    let date = value.dateVal
    $date.year & "-" & twoDigits(date.month) & "-" & twoDigits(date.day)
  of TomlValueKind.Time:
    let time = value.timeVal
    twoDigits(time.hour) & ":" & twoDigits(time.minute) & ":" &
      twoDigits(time.second)
  of TomlValueKind.Datetime:
    let dateTime = value.dateTimeVal
    var text = $dateTime.date.year & "-" & twoDigits(dateTime.date.month) &
      "-" & twoDigits(dateTime.date.day) & "T" & twoDigits(dateTime.time.hour) &
      ":" & twoDigits(dateTime.time.minute) & ":" & twoDigits(dateTime.time.second)
    if dateTime.shift:
      text.add(if dateTime.isShiftPositive: "+" else: "-")
      text.add(twoDigits(dateTime.zoneHourShift) & ":" &
        twoDigits(dateTime.zoneMinuteShift))
    text
  else:
    raise newException(ValueError, "Value is not a TOML date/time")

proc tomlJsonValue(value: TomlValueRef, key, source: string): JsonNode =
  ## Convert the complete TOML value tree without losing array/table shape.
  if value.isNil:
    raise newException(ValueError, "invalid TOML value for " & key & " in " & source)
  case value.kind
  of TomlValueKind.String: result = newJString(value.stringVal)
  of TomlValueKind.Int: result = newJInt(value.intVal)
  of TomlValueKind.Float: result = newJFloat(value.floatVal)
  of TomlValueKind.Bool: result = newJBool(value.boolVal)
  of TomlValueKind.Datetime, TomlValueKind.Date, TomlValueKind.Time:
    result = newJString(tomlDateText(value))
  of TomlValueKind.Array:
    result = newJArray()
    for index, child in value.arrayVal:
      result.add(tomlJsonValue(child, key & "[" & $index & "]", source))
  of TomlValueKind.Table:
    result = newJObject()
    for childKey, child in value.tableVal[]:
      result[childKey] = tomlJsonValue(child, key & "." & childKey, source)
  of TomlValueKind.None:
    raise newException(ValueError, "unsupported TOML value for " & key & " in " & source)

proc loadTomlStructuredConfig*(path: string): Table[string, JsonNode] =
  ## Parse complete TOML and retain structured root values for AppConfig.
  let root = parsetoml.parseFile(path)
  if root.isNil or root.kind != TomlValueKind.Table:
    raise newException(ValueError, "TOML config root must be a table")
  result = initTable[string, JsonNode]()
  for key, value in root.tableVal[]:
    validateTomlConfigType(key, value, path)
    if value.kind notin {TomlValueKind.Array, TomlValueKind.Table,
                         TomlValueKind.Datetime, TomlValueKind.Date, TomlValueKind.Time} and
       not isSupportedTomlKey(key):
      raise newException(ValueError, "unknown TOML config key: " & key)
    if isSecretKey(key) and key.toLowerAscii() != "secrets" and
       value.kind in {TomlValueKind.Array, TomlValueKind.Table,
                                           TomlValueKind.Datetime, TomlValueKind.Date,
                                           TomlValueKind.Time}:
      raise newException(ValueError,
        "structured secret value is not supported: " & key)
    result[key] = tomlJsonValue(value, key, path)

proc isSupportedTomlKey(key: string): bool =
  ## Keep TOML's flexible document shape from silently becoming ignored config.
  let normalized = key.toLowerAscii()
  normalized in [
    "environment", "mahanaim_env", "debug", "mahanaim_debug", "host",
    "mahanaim_host", "port", "mahanaim_port", "request_timeout_ms",
    "mahanaim_request_timeout_ms", "executor_max_concurrent_jobs",
    "mahanaim_executor_max_concurrent_jobs", "executor_max_queued_jobs",
    "mahanaim_executor_max_queued_jobs"
  ] or normalized.startsWith("secret.") or
    normalized.startsWith("secrets.") or normalized.startsWith("secret_")

proc tomlScalar(value: TomlValueRef, key, source: string): string =
  ## Convert only values that have a lossless representation in AppConfig.
  if value.isNil:
    raise newException(ValueError, "invalid TOML value for " & key & " in " & source)
  case value.kind
  of TomlValueKind.String: value.stringVal
  of TomlValueKind.Int: $value.intVal
  of TomlValueKind.Float: $value.floatVal
  of TomlValueKind.Bool: $value.boolVal
  of TomlValueKind.Array, TomlValueKind.Table, TomlValueKind.None,
     TomlValueKind.Datetime, TomlValueKind.Date, TomlValueKind.Time:
    raise newException(ValueError,
      "unsupported TOML value type for " & key & " in " & source)

proc flattenTomlValue(values: var Table[string, string], value: TomlValueRef,
                      prefix, source: string) =
  if value.kind == TomlValueKind.Table:
    for key, child in value.tableVal[]:
      let fullKey = if prefix.len == 0: key else: prefix & "." & key
      flattenTomlValue(values, child, fullKey, source)
    return
  if not isSupportedTomlKey(prefix):
    raise newException(ValueError, "unknown TOML config key: " & prefix)
  validateTomlConfigType(prefix, value, source)
  values[prefix] = tomlScalar(value, prefix, source)

proc loadTomlConfig*(path: string): Table[string, string] =
  ## Parse complete TOML syntax, then flatten supported scalar schema fields.
  let root = parsetoml.parseFile(path)
  if root.isNil or root.kind != TomlValueKind.Table:
    raise newException(ValueError, "TOML config root must be a table")
  result = initTable[string, string]()
  for key, value in root.tableVal[]:
    flattenTomlValue(result, value, key, path)

proc loadStructuredEnvironmentValues(): Table[string, JsonNode] =
  ## Environment variables are strings, but extension configuration often
  ## needs arrays or nested objects. Keep that conversion explicit behind a
  ## namespaced prefix instead of guessing the type of every process variable.
  ## `MAHANAIM_VALUE_FEATURES={"beta":true}` becomes the typed `features` root
  ## value and is applied after file providers, preserving environment
  ## precedence while reusing the same secret/type validation boundary.
  const prefix = "MAHANAIM_VALUE_"
  result = initTable[string, JsonNode]()
  for key, rawValue in envPairs():
    if not key.startsWith(prefix):
      continue
    let valueKey = key[prefix.len .. ^1].strip().toLowerAscii()
    if valueKey.len == 0:
      raise newException(ValueError,
        "structured environment key must not be empty")
    try:
      result[valueKey] = parseJson(rawValue)
    except CatchableError:
      ## Do not include the raw value: configuration errors must not disclose
      ## process environment contents, which may contain sensitive data.
      raise newException(ValueError,
        "invalid JSON for structured environment key: " & valueKey)

proc loadConfig*(dotEnvPath = ".env", jsonPath = "", tomlPath = ""): AppConfig =
  ## Merge files first, then process environment variables as highest priority.
  result = defaultConfig()
  if dotEnvPath.len > 0 and fileExists(dotEnvPath):
    result.applyValues(loadDotEnv(dotEnvPath), dotEnvPath)
  if jsonPath.len > 0:
    result.applyValues(loadJsonConfig(jsonPath), jsonPath)
    result.applyStructuredValues(loadJsonStructuredConfig(jsonPath), jsonPath)
  if tomlPath.len > 0:
    result.applyStructuredValues(loadTomlStructuredConfig(tomlPath), tomlPath)
  var environmentValues = initTable[string, string]()
  for key in ["MAHANAIM_ENV", "MAHANAIM_DEBUG", "MAHANAIM_HOST", "MAHANAIM_PORT",
              "MAHANAIM_REQUEST_TIMEOUT_MS", "MAHANAIM_EXECUTOR_MAX_CONCURRENT_JOBS",
              "MAHANAIM_EXECUTOR_MAX_QUEUED_JOBS"]:
    if existsEnv(key):
      environmentValues[key] = getEnv(key)
  for key, value in envPairs():
    if key.toLowerAscii().startsWith("secret_"):
      environmentValues[key] = value
  result.applyValues(environmentValues, "process environment")
  result.applyStructuredValues(loadStructuredEnvironmentValues(),
    "process environment")

proc redactSecrets*(text: string, config: AppConfig): string =
  ## Replace configured secret values before text reaches logs or error pages.
  result = text
  for _, secret in config.secrets:
    if secret.len > 0:
      result = result.replace(secret, "[REDACTED]")

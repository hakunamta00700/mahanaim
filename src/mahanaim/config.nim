## Configuration providers and secret-safe rendering.
##
## Providers are intentionally small and composable. `.env` is useful for
## local development, JSON/TOML are explicit deployment inputs, and process
## environment variables always win over file values.

import std/[json, os, strutils, tables]
import parsetoml

type
  AppConfig* = object
    ## Runtime settings plus a separate secret store.
    environment*: string
    debug*: bool
    host*: string
    port*: int
    requestTimeoutMs*: int
    executorMaxConcurrentJobs*: int
    secrets*: Table[string, string]

proc newConfig(environment, host: string, debug: bool, port: int): AppConfig =
  result = AppConfig(environment: environment, debug: debug, host: host,
    port: port, requestTimeoutMs: 0, executorMaxConcurrentJobs: 0)
  result.secrets = initTable[string, string]()

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
      result[key] = if value.kind == JString: value.getStr() else: $value

proc isSupportedTomlKey(key: string): bool =
  ## Keep TOML's flexible document shape from silently becoming ignored config.
  let normalized = key.toLowerAscii()
  normalized in [
    "environment", "mahanaim_env", "debug", "mahanaim_debug", "host",
    "mahanaim_host", "port", "mahanaim_port", "request_timeout_ms",
    "mahanaim_request_timeout_ms", "executor_max_concurrent_jobs",
    "mahanaim_executor_max_concurrent_jobs"
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
  values[prefix] = tomlScalar(value, prefix, source)

proc loadTomlConfig*(path: string): Table[string, string] =
  ## Parse complete TOML syntax, then flatten supported scalar schema fields.
  let root = parsetoml.parseFile(path)
  if root.isNil or root.kind != TomlValueKind.Table:
    raise newException(ValueError, "TOML config root must be a table")
  result = initTable[string, string]()
  for key, value in root.tableVal[]:
    flattenTomlValue(result, value, key, path)

proc loadConfig*(dotEnvPath = ".env", jsonPath = "", tomlPath = ""): AppConfig =
  ## Merge files first, then process environment variables as highest priority.
  result = defaultConfig()
  if dotEnvPath.len > 0 and fileExists(dotEnvPath):
    result.applyValues(loadDotEnv(dotEnvPath), dotEnvPath)
  if jsonPath.len > 0:
    result.applyValues(loadJsonConfig(jsonPath), jsonPath)
  if tomlPath.len > 0:
    result.applyValues(loadTomlConfig(tomlPath), tomlPath)
  var environmentValues = initTable[string, string]()
  for key in ["MAHANAIM_ENV", "MAHANAIM_DEBUG", "MAHANAIM_HOST", "MAHANAIM_PORT",
              "MAHANAIM_REQUEST_TIMEOUT_MS", "MAHANAIM_EXECUTOR_MAX_CONCURRENT_JOBS"]:
    if existsEnv(key):
      environmentValues[key] = getEnv(key)
  for key, value in envPairs():
    if key.toLowerAscii().startsWith("secret_"):
      environmentValues[key] = value
  result.applyValues(environmentValues, "process environment")

proc redactSecrets*(text: string, config: AppConfig): string =
  ## Replace configured secret values before text reaches logs or error pages.
  result = text
  for _, secret in config.secrets:
    if secret.len > 0:
      result = result.replace(secret, "[REDACTED]")

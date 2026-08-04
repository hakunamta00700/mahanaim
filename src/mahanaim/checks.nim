## Pre-flight framework checks.
##
## Checks are pure inspection functions rather than startup side effects.  This
## lets the CLI, CI, and an embedding application execute the same validation
## contract before opening a socket or running application lifecycle hooks.

import std/[strutils, tables]
import ./application
import ./config
import ./core
import ./database
import ./execution
import ./models
import ./migration_commands
import ./router
import ./security

type
  CheckSeverity* = enum
    checkError
    checkWarning

  CheckIssue* = object
    ## A stable code makes CLI output and future machine-readable reports useful.
    severity*: CheckSeverity
    code*: string
    message*: string

  CheckReport* = object
    ## Reports aggregate all issues so CI can fix several configuration errors
    ## in one run instead of failing at the first discovered problem.
    issues*: seq[CheckIssue]

proc initCheckReport*(): CheckReport =
  result.issues = @[]

proc addIssue(report: var CheckReport, severity: CheckSeverity,
              code, message: string) =
  report.issues.add(CheckIssue(severity: severity, code: code, message: message))

proc addError*(report: var CheckReport, code, message: string) =
  ## Record a blocking pre-flight issue.
  report.addIssue(checkError, code, message)

proc addWarning*(report: var CheckReport, code, message: string) =
  ## Record a non-blocking issue that should still be visible in CI output.
  report.addIssue(checkWarning, code, message)

proc passed*(report: CheckReport): bool =
  ## Warnings are visible but do not prevent a development boot.
  for issue in report.issues:
    if issue.severity == checkError:
      return false
  true

proc checkConfig*(config: AppConfig): CheckReport =
  ## Validate values that would make a server boot predictably impossible.
  result = initCheckReport()
  if config.environment.strip().len == 0:
    result.addError("config.environment.empty", "environment must not be empty")
  if config.host.strip().len == 0:
    result.addError("config.host.empty", "host must not be empty")
  if config.port < 1 or config.port > 65535:
    result.addError("config.port.invalid", "port must be between 1 and 65535")
  if config.requestTimeoutMs < 0:
    result.addError("config.request-timeout.negative",
      "requestTimeoutMs must be zero or greater")
  if config.executorMaxConcurrentJobs < 0:
    result.addError("config.executor-capacity.negative",
      "executorMaxConcurrentJobs must be zero or greater")
  for key, value in config.secrets:
    if key.strip().len == 0:
      result.addError("config.secret.empty-key", "secret keys must not be empty")
    if value.len == 0:
      result.addWarning("config.secret.empty-value", "secret values should not be empty")

proc checkRouter*(router: Router): CheckReport =
  ## Inspect route metadata without invoking user handlers.
  result = initCheckReport()
  var seenNames = initTable[string, bool]()
  var seenRoutes = initTable[string, bool]()
  for route in router.routes:
    if route.httpMethod.strip().len == 0:
      result.addError("route.method.empty", "route method must not be empty")
    if route.pattern.len == 0 or not route.pattern.startsWith("/"):
      result.addError("route.pattern.invalid",
        "route patterns must be absolute paths")
    if route.handler.isNil:
      result.addError("route.handler.missing",
        "every registered route must have a handler")
    if route.name.len > 0:
      if seenNames.hasKey(route.name):
        result.addError("route.name.duplicate", "duplicate route name: " & route.name)
      seenNames[route.name] = true
    let routeKey = route.httpMethod & " " & route.pattern
    if seenRoutes.hasKey(routeKey):
      result.addError("route.declaration.duplicate",
        "duplicate route declaration: " & routeKey)
    seenRoutes[routeKey] = true

proc checkSecurityPolicy*(policy: SecurityPolicy): CheckReport =
  ## Validate policy shape before middleware can reject every request.
  result = initCheckReport()
  if policy.maxBodyBytes < 0:
    result.addError("security.body-limit.negative",
      "maxBodyBytes must be zero or greater")
  if policy.rateLimitRequests < 0:
    result.addError("security.rate-limit.requests-negative",
      "rateLimitRequests must be zero or greater")
  if policy.rateLimitWindowSeconds < 0:
    result.addError("security.rate-limit.window-negative",
      "rateLimitWindowSeconds must be zero or greater")
  if policy.rateLimitRequests > 0 and policy.rateLimitWindowSeconds == 0:
    result.addError("security.rate-limit.window-required",
      "an enabled rate limit requires a positive window")
  if policy.rateLimitRequests > 0 and policy.rateLimitKey.strip().len == 0:
    result.addError("security.rate-limit.key.empty",
      "an enabled rate limit requires a non-empty store key")
  if policy.contentSecurityPolicy.strip().len == 0:
    result.addError("security.csp.empty", "content security policy must not be empty")
  if policy.frameOptions.strip().len == 0:
    result.addError("security.frame-options.empty", "frame options must not be empty")
  if policy.referrerPolicy.strip().len == 0:
    result.addError("security.referrer-policy.empty", "referrer policy must not be empty")
  if policy.csrfEnabled and policy.csrfSecret.len < 32:
    result.addError("security.csrf-secret.weak",
      "enabled CSRF policy requires a secret of at least 32 characters")
  if policy.csrfEnabled and policy.csrfCookieName.strip().len == 0:
    result.addError("security.csrf-cookie.empty", "CSRF cookie name must not be empty")
  if policy.csrfEnabled and policy.csrfHeaderName.strip().len == 0:
    result.addError("security.csrf-header.empty", "CSRF header name must not be empty")
  if policy.session.enabled and policy.session.secret.len < 32:
    result.addError("security.session-secret.weak",
      "enabled session policy requires a secret of at least 32 characters")
  if policy.session.enabled and policy.session.cookieName.strip().len == 0:
    result.addError("security.session-cookie.empty",
      "enabled session policy requires a cookie name")
  for legacySecret in policy.session.legacySecrets:
    if legacySecret.len < 32:
      result.addError("security.session-legacy-secret.weak",
        "legacy session secrets must be at least 32 characters")
  for host in policy.allowedHosts:
    if host.strip().len == 0:
      result.addError("security.host.empty", "allowed hosts must not contain empty values")
  for origin in policy.allowedOrigins:
    if origin.strip().len == 0:
      result.addError("security.origin.empty", "allowed origins must not contain empty values")

proc checkModels*(registry: ModelRegistry): CheckReport =
  ## Validate metadata references before a future migration compiler runs.
  result = initCheckReport()
  for modelName, metadata in registry.models:
    if modelName.strip().len == 0 or metadata.name.strip().len == 0:
      result.addError("model.name.empty", "model names must not be empty")
    if metadata.tableName.strip().len == 0:
      result.addError("model.table.empty", "model table names must not be empty")
    var primaryKeys = 0
    for field in metadata.fields:
      if field.name.strip().len == 0:
        result.addError("model.field.empty", "model field names must not be empty")
      if field.columnName.strip().len == 0:
        result.addError("model.column.empty", "model column names must not be empty")
      if field.primaryKey:
        inc primaryKeys
      if field.maxLength < 0:
        result.addError("model.field.max-length.invalid",
          "model field maxLength must not be negative: " & metadata.name & "." & field.name)
    if primaryKeys > 1:
      result.addError("model.primary-key.multiple",
        "model metadata must declare at most one primary key field: " & metadata.name)
    for index in metadata.indexes:
      if index.name.strip().len == 0:
        result.addError("model.index.empty-name", "model index names must not be empty")
      for fieldName in index.fields:
        if not metadata.hasField(fieldName):
          result.addError("model.index.unknown-field",
            "index references unknown field: " & metadata.name & "." & fieldName)
    for relation in metadata.relations:
      if not metadata.hasField(relation.localField):
        result.addError("model.relation.unknown-local-field",
          "relation references unknown local field: " & metadata.name & "." & relation.localField)
      if relation.targetModel.strip().len == 0:
            result.addError("model.relation.empty-target",
        "relation target model must not be empty: " & metadata.name & "." & relation.name)

proc checkMigrations*(registry: MigrationRegistry,
                      sqlitePath: string): CheckReport =
  ## Inspect application-owned migration definitions without opening a
  ## database. This makes CLI, CI, and embedding checks agree while keeping
  ## migration execution an explicit command-side effect.
  result = initCheckReport()
  if registry.isNil:
    result.addError("migration.registry.missing", "migration registry is required")
    return
  if sqlitePath.strip().len == 0:
    result.addError("migration.path.empty", "migration SQLite path must not be empty")
  var names = initTable[string, bool]()
  try:
    for migration in registry.loadMigrations():
      if migration.name.strip().len == 0:
        result.addError("migration.name.empty", "migration names must not be empty")
      elif names.hasKey(migration.name):
        result.addError("migration.name.duplicate",
          "duplicate migration name: " & migration.name)
      else:
        names[migration.name] = true
      for operation in migration.up:
        try:
          discard migrationSql(operation, dialectSqlite)
        except CatchableError as error:
          result.addError("migration.operation.invalid", error.msg)
      for operation in migration.down:
        try:
          discard migrationSql(operation, dialectSqlite)
        except CatchableError as error:
          result.addError("migration.rollback.invalid", error.msg)
  except CatchableError as error:
    result.addError("migration.provider.failed", error.msg)

proc checkExecution*(router: Router,
                     policy = defaultExecutionPolicy()): CheckReport =
  ## Surface sync handlers during pre-flight so blocking work is reviewed before
  ## boot. Strict deployments can turn the warning into a blocking error.
  result = initCheckReport()
  if policy.blockingDetectionMs < 0:
    result.addError("execution.blocking-detection.negative",
      "blockingDetectionMs must be zero or greater")
  if policy.forceCancellationAfterMs < 0:
    result.addError("execution.force-cancellation.negative",
      "forceCancellationAfterMs must be zero or greater")
  if policy.queueWaitMs < 0:
    result.addError("execution.queue-wait.negative",
      "queueWaitMs must be zero or greater")
  if policy.forceCancellationAfterMs > 0 and
     policy.blockingDetectionMs > 0 and
     policy.forceCancellationAfterMs < policy.blockingDetectionMs:
    result.addWarning("execution.force-cancellation.before-detection",
      "force cancellation may occur before blocking detection is reported")
  for route in router.routes:
    if route.executionKind != hekSync:
      continue
    if not policy.allowSynchronousHandlers:
      result.addError("execution.sync.disabled",
        "synchronous handler is disabled: " & route.name)
    elif policy.warnOnSynchronousHandlers:
      result.addWarning("execution.sync.handler",
        "synchronous handler is executor-bound; review blocking and thread-safety: " & route.name)

proc checkApplicationWithPolicy(app: Application,
                                 securityPolicy: SecurityPolicy): CheckReport =
  ## Combine the same checks used by CLI and embedding applications while
  ## making the policy source explicit for the overloads below.
  result = initCheckReport()
  let configReport = checkConfig(app.config)
  let routeReport = checkRouter(app.router)
  let modelReport = checkModels(app.models)
  let migrationReport = checkMigrations(app.migrationRegistry,
    app.migrationDatabasePath)
  let securityReport = checkSecurityPolicy(securityPolicy)
  let executionReport = checkExecution(app.router, app.executionPolicy)
  result.issues.add(configReport.issues)
  result.issues.add(routeReport.issues)
  result.issues.add(modelReport.issues)
  result.issues.add(migrationReport.issues)
  result.issues.add(securityReport.issues)
  result.issues.add(executionReport.issues)

proc checkApplication*(app: Application): CheckReport =
  ## Inspect the policy installed into this Application. This is the default
  ## path used by CLI/CI so validation cannot drift from runtime middleware.
  if app.isNil:
    result = initCheckReport()
    result.addError("application.missing", "application is required")
    return
  checkApplicationWithPolicy(app, app.securityPolicy)

proc checkApplication*(app: Application,
                       securityPolicy: SecurityPolicy): CheckReport =
  ## Keep an explicit-policy overload for callers validating a candidate
  ## policy before replacing the application's configured one.
  if app.isNil:
    result = initCheckReport()
    result.addError("application.missing", "application is required")
    return
  checkApplicationWithPolicy(app, securityPolicy)

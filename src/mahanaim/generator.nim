## Project generator for the `mahanaim new` command.
##
## Generation is isolated from the CLI parser so it can be tested directly and
## reused by another command frontend later.

import std/[os, sequtils, strutils]

type ProjectSpec* = object
  name*: string
  root*: string

type AppSpec* = object
  ## A Django-like app is an explicit Mahanaim module stored inside an existing
  ## project.  The project root is supplied rather than inferred from cwd so
  ## the generator never writes outside the caller's intended project.
  name*: string
  root*: string

proc validProjectName*(name: string): bool =
  ## Restrict generated Nim identifiers to a predictable safe subset.
  if name.len == 0 or not (name[0].isAlphaAscii or name[0] == '_'):
    return false
  for character in name:
    if not (character.isAlphaNumeric or character == '_'):
      return false
  true

proc writeIfMissing(path, content: string) =
  ## Never overwrite user files: project generation must be recoverable.
  if fileExists(path):
    raise newException(IOError, "refusing to overwrite existing file: " & path)
  writeFile(path, content)

proc initializeGeneratedRepository(root: string) =
  ## Nimble 2.2 reads VCS metadata before it dispatches a custom `test` task.
  ## Give the generated, otherwise empty project one self-contained baseline so
  ## `nimble test` works immediately and never relies on caller Git settings.
  if findExe("git").len == 0:
    raise newException(IOError,
      "Git is required to create a Mahanaim project because Nimble test uses VCS metadata")
  let rootArgument = quoteShell(root)
  if execShellCmd("git -C " & rootArgument & " init") != 0:
    raise newException(IOError, "unable to initialize generated project Git repository")
  if execShellCmd("git -C " & rootArgument & " add --all") != 0:
    raise newException(IOError, "unable to stage generated project files")
  let commitCommand = "git -C " & rootArgument &
    " -c " & quoteShell("user.name=Mahanaim generator") &
    " -c " & quoteShell("user.email=generator@mahanaim.local") &
    " commit --quiet -m " & quoteShell("Initial Mahanaim project")
  if execShellCmd(commitCommand) != 0:
    raise newException(IOError, "unable to create generated project baseline commit")

proc generateApp*(spec: AppSpec) =
  ## Create a small, compilable application module and its isolated contract
  ## test.  Existing application wiring remains untouched: the developer adds
  ## `app.installModules([<name>Module()])` deliberately where composition is
  ## owned, rather than relying on Django-style global discovery.
  if not validProjectName(spec.name):
    raise newException(ValueError, "app name must be a valid Nim identifier")
  if spec.root.strip().len == 0 or not dirExists(spec.root):
    raise newException(IOError, "app project root must be an existing directory")
  let sourceDirectory = spec.root / "src"
  let testDirectory = spec.root / "tests"
  if not dirExists(sourceDirectory) or not dirExists(testDirectory):
    raise newException(IOError, "app project root requires src and tests directories")
  let routeName = spec.name.replace('_', '-')
  let routePath = "/" & routeName & "/health"
  let moduleSource = "## Generated Mahanaim application module.\n" &
    "## Install explicitly: app.installModules([" & spec.name & "Module()])\n\n" &
    "import std/asyncdispatch\nimport mahanaim\n\n" &
    "proc " & spec.name & "Health(request: Request): Future[Response] {.async, gcsafe.} =\n" &
    "  discard request\n" &
    "  return textResponse(\"" & spec.name & " app is ready\")\n\n" &
    "proc " & spec.name & "Module*(): ApplicationModule =\n" &
    "  result = newApplicationModule(\"" & spec.name & "\")\n" &
    "  result.addModuleRoute(proc(app: Application) {.gcsafe.} =\n" &
    "    app.get(\"" & routePath & "\", \"" & routeName & "-health\", " &
      spec.name & "Health))\n"
  writeIfMissing(sourceDirectory / (spec.name & ".nim"), moduleSource)
  let testSource = "import std/[asyncdispatch, httpcore, unittest]\n" &
    "import mahanaim\nimport " & spec.name & "\n\n" &
    "suite \"generated " & spec.name & " app module\":\n" &
    "  test \"installs through explicit application composition\":\n" &
    "    let app = newApplication()\n" &
    "    app.installModules([" & spec.name & "Module()])\n" &
    "    let response = waitFor app.dispatch(newRequest(\"GET\", \"" &
      routePath & "\"))\n" &
    "    check response.status == Http200\n" &
    "    check response.body == \"" & spec.name & " app is ready\"\n"
  writeIfMissing(testDirectory / ("test_" & spec.name & ".nim"), testSource)

proc generateProject*(spec: ProjectSpec) =
  ## Create a deterministic vertical slice rather than an empty placeholder:
  ## configuration is visible, the generated app has one health route, and the
  ## generated test exercises the same Application.dispatch contract used by
  ## the framework suite. More features can be added without changing this
  ## module/package boundary.
  if not validProjectName(spec.name):
    raise newException(ValueError, "project name must be a valid Nim identifier")
  if dirExists(spec.root) and getFileInfo(spec.root).kind == pcDir:
    if toSeq(walkDir(spec.root)).len > 0:
      raise newException(IOError, "project directory is not empty: " & spec.root)
  else:
    createDir(spec.root)

  let srcDir = spec.root / "src"
  let testDir = spec.root / "tests"
  createDir(srcDir)
  createDir(testDir)
  writeIfMissing(spec.root / "README.md",
    "# " & spec.name & "\n\n" &
    "Generated by Mahanaim.\n\n" &
    "## Development\n\n" &
    "Mahanaim creates an initial Git commit because Nimble 2.2 reads VCS metadata " &
    "before it runs project tests. Set your own Git identity and amend that commit if needed.\n\n" &
    "```text\n" &
    "nimble install\n" &
    "nimble test\n" &
    "nimble build\n" &
    "```\n")
  writeIfMissing(spec.root / ".env.example",
    "MAHANAIM_ENV=development\n" &
    "MAHANAIM_HOST=127.0.0.1\n" &
    "MAHANAIM_PORT=8000\n")
  writeIfMissing(spec.root / ".gitignore",
    ".env\n" &
    "nimcache/\n" &
    "*.exe\n")
  writeIfMissing(spec.root / (spec.name & ".nimble"),
    "import std/[os, strutils]\n\n" &
    "version = \"0.1.0\"\n" &
    "author = \"" & spec.name & " contributors\"\n" &
    "description = \"" & spec.name & " application built with Mahanaim\"\n" &
    "license = \"MIT\"\n" &
    "srcDir = \"src\"\n\n" &
    "bin = @[\"" & spec.name & "\"]\n\n" &
    "requires \"mahanaim >= 0.1.0\"\n" &
    "requires \"nim >= 2.2.0\"\n\n" &
    "proc dependencyPathArgs(): string =\n" &
    "  ## A task invokes Nim directly, so resolve installed package paths\n" &
    "  ## explicitly instead of relying on ambient compiler configuration.\n" &
    "  var frameworkRoot = getEnv(\"MAHANAIM_FRAMEWORK_ROOT\").strip()\n" &
    "  if frameworkRoot.len == 0:\n" &
    "    frameworkRoot = staticExec(\"nimble path mahanaim\").strip()\n" &
    "  if frameworkRoot.len > 0:\n" &
    "    let frameworkSource = if fileExists(frameworkRoot / \"src\" / \"mahanaim.nim\"):\n" &
    "      frameworkRoot / \"src\" else: frameworkRoot\n" &
    "    result.add(\" --path:\" & quoteShell(frameworkSource))\n" &
    "  let packageNames = \"nimcrypto parsetoml prologue taskpools db_connector argon2 checksums timezones cookiejar httpx ioselectors wepoll logue cligen regex unicodedb\"\n" &
    "  for path in staticExec(\"nimble path \" & packageNames).splitLines:\n" &
    "    let normalized = path.strip()\n" &
    "    if normalized.len > 0:\n" &
    "      result.add(\" --path:\" & quoteShell(normalized))\n\n" &
    "task test, \"Run the generated application tests\":\n" &
    "  ## The generated baseline commit satisfies Nimble's VCS metadata\n" &
    "  ## requirement; this task keeps the test command deterministic.\n" &
    "  exec \"nim c --path:src\" & dependencyPathArgs() & \" -r tests/test_app.nim\"\n")
  writeIfMissing(srcDir / (spec.name & ".nim"),
    """## Generated application entry point.
##
## The starter deliberately wires one small model through the framework's
## metadata, migration, CRUD, admin, authentication, and documentation seams.
## Applications can replace these declarations while keeping the boundaries.

import std/[asyncdispatch, os]
import mahanaim

proc health(request: Request): Future[Response] {.async, gcsafe.} =
  ## Keep the handler capture-free; observability state belongs to Application.
  discard request
  return jsonResponse("{\"status\":\"ok\"}")

proc generatedApplicationModule(): ApplicationModule =
  ## Generated projects demonstrate explicit composition: routes and lifecycle
  ## hooks belong to a named module rather than implicit package discovery.
  result = newApplicationModule("generated-app")
  result.addModuleRoute(proc(app: Application) {.gcsafe.} =
    app.get("/health", "health", health))
  result.onModuleStartup(proc() {.gcsafe.} = discard)

proc sliceMetadata(): ModelMetadata =
  ## One explicit metadata source feeds migration, validation, CRUD, and forms.
  result = createModelMetadata("Item", "items")
  result.addField(newModelField("id", modelInteger, primaryKey = true))
  result.addField(newModelField("title", modelString))

proc sliceMigrations(): seq[Migration] =
  ## Keep migration discovery explicit and deterministic for both the runtime
  ## app and its standalone db CLI; no source-file scanning is involved.
  let metadata = sliceMetadata()
  result.add(migrationFromMetadata(metadata, "001_items"))

proc slicePolicy(): SecurityPolicy =
  ## Development defaults are explicit so generated tests can exercise the
  ## same CSRF/session boundary without relying on ambient environment state.
  result = defaultSecurityPolicy()
  result.csrfEnabled = true
  result.csrfSecret = "generated-app-csrf-secret-that-is-long-enough"
  result.csrfCookieSecure = false
  result.session.enabled = true
  result.session.cookieName = "mahanaim_session"
  result.session.secret = "generated-app-session-secret-that-is-long-enough"
  result.session.secureCookie = false

proc createApp*(config = loadConfig()): Application =
  ## Application construction owns the adapter and closes it with lifecycle.
  let policy = slicePolicy()
  let app = newApplication(config, policy)
  let adapter = newSqliteDatabaseAdapter()
  let metadata = sliceMetadata()
  let migrations = sliceMigrations()
  discard executeMigrationCommand(adapter, migrations,
    parseMigrationCommand(["migrate"]))
  let migrationRegistry = newMigrationRegistry()
  proc migrationProvider(): seq[Migration] {.gcsafe.} =
    ## The provider is project-owned and can be consumed by embedded and
    ## standalone command frontends through the same Application contract.
    sliceMigrations()
  migrationRegistry.registerMigrations(migrationProvider)
  app.configureMigrations(migrationRegistry)
  app.onShutdown(proc() {.gcsafe.} = adapter.close())

  let repository = newDatabaseRepository(metadata, adapter)
  let store = newDatabaseRepositoryResourceStore(repository)
  registerCrudRoutes(app, newCrudResource(metadata, store), "/items", "items")
  app.installModules([generatedApplicationModule()])

  let accountStore = newInMemoryAccountCredentialStore()
  let hasher = newPbkdf2PasswordHasher(iterations = 10000)
  accountStore.addAccount(AccountCredential(subject: "admin-1",
    identifier: "admin@example.test", passwordHash: hasher.hashPassword(
      "admin-password"), enabled: true))
  let authentication = newAccountAuthentication(accountStore, hasher,
    policy.session, newInMemoryLoginThrottle())
  app.registerAccountAuthenticationRoutes(authentication)
  app.configureAdminUserCreator(newAdminUserCreator(accountStore, hasher))

  let adminRegistry = newAdminRegistry()
  proc authorize(request: Request): bool {.gcsafe.} =
    request.auth.authenticated and request.auth.subject == "admin-1"
  adminRegistry.registerAdminResource("items", "/admin/items", metadata,
    store, authorize, formPolicy = policy)
  registerAdminRoutes(app, adminRegistry)

  ## Route collection is intentionally performed at construction time so a
  ## generated application fails early if a route cannot be documented.
  let openApi = newOpenApiRegistry("Generated API", "0.1.0")
  discard openApi.collectRoutes(app.router)
  result = app

when isMainModule:
  ## The generated module is the explicit standalone entry point: project
  ## wiring remains in createApp while the shared CLI owns parsing/dispatch.
  ## Startup/shutdown are explicit here so adapters opened during construction
  ## are released even when a command handler raises an exception.
  let app = createApp()
  app.startup()
  var exitCode = 0
  try:
    exitCode = runCli(app, commandLineParams())
  finally:
    app.shutdown()
  quit(exitCode)
""")
  writeIfMissing(testDir / "test_app.nim",
    """import std/[asyncdispatch, httpcore, json, os, tables, unittest]
import mahanaim
import """ & spec.name & """

suite "generated app vertical slice":
  test "generated app composes CRUD auth admin OpenAPI and lifecycle":
    let app = createApp()
    let client = newTestClient(app)
    let anonymousForm = waitFor client.get("/admin/items/new")
    check anonymousForm.status == Http403
    let csrf = client.cookies["mahanaim_csrf"]
    let csrfHeaders = [("x-csrf-token", csrf)]
    let login = waitFor client.post("/login",
      "{\"identifier\":\"admin@example.test\",\"password\":\"admin-password\"}",
      headers = csrfHeaders)
    check login.status == Http200
    check (waitFor client.get("/admin/items/new")).status == Http200
    let created = waitFor client.post("/items", "{\"title\":\"generated\"}",
      headers = csrfHeaders)
    check created.status == Http201
    check parseJson(created.body)["title"].getStr() == "generated"
    let listed = waitFor client.get("/admin/items")
    check listed.status == Http200
    check parseJson(listed.body)[0]["title"].getStr() == "generated"

    let openApi = newOpenApiRegistry("Generated API", "0.1.0")
    check openApi.collectRoutes(app.router) > 0
    check openApi.document()["paths"].hasKey("/items")
    check openApi.document()["paths"].hasKey("/admin/items")
    check app.runCli(["db", "status"]) == 0
    putEnv("MAHANAIM_ADMIN_PASSWORD", "generated-cli-password")
    defer: delEnv("MAHANAIM_ADMIN_PASSWORD")
    check app.runCli(["admin", "create-user", "cli@example.test", "cli-user"]) == 0

    app.startup()
    let health = waitFor client.get("/health")
    check health.status == Http200
    check health.headers.hasKey("x-request-id")
    check healthResponse(app.observability).status == Http200
    app.shutdown()
    check not app.observability.ready
""")
  initializeGeneratedRepository(spec.root)

## Definition of Done document contract.
##
## The checklist is a release input, not only prose. This test keeps its
## required sections and verification commands machine-checkable so a future
## edit cannot silently remove the evidence boundary from the framework.

import std/[os, osproc, sequtils, strutils, unittest]
import mahanaim

proc localMarkdownTargets(contents: string): seq[string] =
  ## Collect relative Markdown destinations without treating anchors or external
  ## URLs as filesystem paths. This keeps the documentation navigation contract
  ## runnable on every CI platform without a browser dependency.
  var offset = 0
  while true:
    let start = contents.find("](", offset)
    if start < 0:
      break
    let close = contents.find(')', start + 2)
    if close < 0:
      break
    let raw = contents[start + 2 ..< close]
    let target = raw.split('#', maxsplit = 1)[0].strip()
    if target.len > 0 and not target.contains("://") and
        not target.startsWith("mailto:") and not target.startsWith("/"):
      result.add(target)
    offset = close + 1

proc markdownLinkIssues(root: string): seq[string] =
  var documents = @[root / "README.md"]
  for path in walkDirRec(root / "docs"):
    if splitFile(path).ext.toLowerAscii() == ".md":
      documents.add(path)
  for document in documents:
    let base = parentDir(document)
    for target in localMarkdownTargets(readFile(document)):
      if not fileExists(base / target):
        result.add(relativePath(document, root) & " -> " & target)

proc unindexedDocumentation(root: string): seq[string] =
  ## `docs/index.md` is the canonical entry point for user-facing material.
  ## Keep its links exhaustive so new guides cannot become repository-only
  ## knowledge that users discover only by browsing source directories.
  let indexPath = root / "docs" / "index.md"
  var indexed: seq[string]
  for target in localMarkdownTargets(readFile(indexPath)):
    indexed.add(normalizedPath(target))
  for path in walkDirRec(root / "docs"):
    if splitFile(path).ext.toLowerAscii() != ".md" or path == indexPath:
      continue
    let relative = normalizedPath(relativePath(path, parentDir(indexPath)))
    if relative notin indexed:
      result.add(relative)

proc publicEntryPointModules(root: string): seq[string] =
  ## Keep the umbrella package honest: every `export` declaration in
  ## `src/mahanaim.nim` is a public module boundary, including optional
  ## PostgreSQL support. Continuation lines are comma-separated just like the
  ## Nim source declaration.
  var collecting = false
  for rawLine in readFile(root / "src" / "mahanaim.nim").splitLines:
    let line = rawLine.strip()
    if line.startsWith("export "):
      collecting = true
      let fragment = line["export ".len .. ^1]
      for name in fragment.split(','):
        let moduleName = name.strip()
        if moduleName.len > 0 and moduleName notin result:
          result.add(moduleName)
      if not line.endsWith(","):
        collecting = false
    elif collecting:
      for name in line.split(','):
        let moduleName = name.strip()
        if moduleName.len > 0 and moduleName notin result:
          result.add(moduleName)
      if not line.endsWith(","):
        collecting = false

suite "definition of done contracts":
  test "internal Markdown links resolve to repository documentation":
    let issues = markdownLinkIssues(getCurrentDir())
    check issues.len == 0

  test "documentation index links every Markdown guide":
    let missing = unindexedDocumentation(getCurrentDir())
    check missing.len == 0

  test "CLI reference follows executable help and exit-code contracts":
    ## The CLI binary is built by the `docsCheck` task before this contract
    ## runs. Verify the public help output and a failure path, then require the
    ## guide to name every advertised command and its status behavior.
    let root = getCurrentDir()
    let executable = root / ("mahanaim_cli" &
      (if ExeExt.len == 0: "" else: "." & ExeExt))
    let guide = readFile(root / "docs" / "cli-reference.md")
    check fileExists(executable)
    let (helpOutput, helpExitCode) = execCmdEx(quoteShell(executable) & " --help")
    check helpExitCode == 0
    let (failureOutput, failureExitCode) = execCmdEx(
      quoteShell(executable) & " definitely-not-a-command")
    check failureExitCode == 1
    check failureOutput.contains("Unknown command")
    for usage in [
      "new NAME [PATH]", "app NAME [PROJECT_ROOT]",
      "db status|migrate|up|rollback [PATH]", "jobs run [max]|recover",
      "openapi [PATH]", "openapi-ts [PATH]",
      "admin create-user <identifier> [subject]",
      "static collect <source...> --output <path>", "dev", "test", "check"
    ]:
      check helpOutput.contains(usage)
      if usage == "jobs run [max]|recover":
        check guide.contains("`jobs run [max]`")
        check guide.contains("`jobs recover`")
      else:
        check guide.contains("`" & usage & "`")
    check guide.contains("성공은 종료 코드 `0`")
    check guide.contains("반환한다. `test`는 내부 `nimble test`의 종료 코드를")

  test "application scaffold documentation matches generator output":
    ## The app command intentionally avoids implicit discovery. Keep the
    ## generated filenames, explicit factory, and health route in lockstep
    ## with the onboarding guides so a copied composition snippet remains
    ## executable after generator changes.
    let generator = readFile(getCurrentDir() / "src" / "mahanaim" /
      "generator.nim")
    let gettingStarted = readFile(getCurrentDir() / "docs" /
      "getting-started.md")
    let projectLayout = readFile(getCurrentDir() / "docs" /
      "project-layout.md")
    for guide in [gettingStarted, projectLayout]:
      check guide.contains("mahanaim app catalog")
      check guide.contains("src/catalog.nim")
      check guide.contains("tests/test_catalog.nim")
      check guide.contains("catalogModule()")
    check gettingStarted.contains("nimble install")
    check gettingStarted.contains("Initial Mahanaim project")
    check projectLayout.contains("baseline commit")
    check generator.contains("src/catalog.nim") == false
    check generator.contains("spec.name & \".nim\"")
    check generator.contains("test_\" & spec.name & \".nim\"")
    check generator.contains("proc \" & spec.name & \"Module*")
    check generator.contains("routePath = \"/\" & routeName & \"/health\"")
    check generator.contains("initializeGeneratedRepository(spec.root)")

  test "template guide documents the common safe failure paths":
    let guide = readFile(getCurrentDir() / "docs" / "templates.md")
    check guide.contains("## 문제 해결")
    for concern in ["XSS", "collection", "template을 찾을 수 없음", "CSRF"]:
      check guide.contains(concern)
    check guide.contains("csrfHiddenInput(request, policy)")

  test "API guide links versioning and deprecation policy":
    let guide = readFile(getCurrentDir() / "docs" / "api-development.md")
    check guide.contains("addVersionedDocumentedRoute")
    check guide.contains("unsupported versions return 406")
    check guide.contains("deprecated operations")
    check guide.contains("[API stability policy](api-stability-policy.md)")

  test "security documentation keeps certificates and secrets out of examples":
    let configuration = readFile(getCurrentDir() / "docs" / "configuration.md")
    let deployment = readFile(getCurrentDir() / "docs" / "deployment.md")
    let checklist = readFile(getCurrentDir() / "docs" /
      "security-deployment-checklist.md")
    check configuration.contains("`.env.example`처럼 값이 없는 예시")
    check configuration.contains("source와 CLI\n  argument에 넣지 않는다")
    check deployment.contains("service environment files outside the repository")
    check checklist.contains("secret을 소스, 설정 파일, 로그, 오류 응답에 저장하지 않는다")
    check checklist.contains("TLS 인증서 만료·갱신 자동화")

  test "extension guides state startup and resource ownership boundaries":
    let extension = readFile(getCurrentDir() / "docs" / "extension-authoring.md")
    let plugins = readFile(getCurrentDir() / "docs" / "plugins.md")
    let coreTests = readFile(getCurrentDir() / "tests" / "test_core.nim")
    check extension.contains("application owns process lifecycle")
    check extension.contains("Never register a route, provider, plugin, or adapter after startup begins")
    check plugins.contains("registration after startup is rejected")
    check plugins.contains("must not mutate global registries")
    check coreTests.contains("plugin registration is closed during and after application startup")

  test "Django feature map links the current admin app command template and plugin boundaries":
    let featureMap = readFile(getCurrentDir() / "docs" / "feature-map.md")
    for guide in ["admin.md", "application-modules.md", "cli-reference.md",
                  "templates.md", "plugins.md"]:
      check featureMap.contains("](" & guide & ")")
    check featureMap.contains("자동 발견보다 명시적 설치")
    check featureMap.contains("Admin은 metadata 기반이지만 실험 기능")

  test "broker and SMTP guides separate local tests from provider guarantees":
    let jobs = readFile(getCurrentDir() / "docs" / "background-jobs.md")
    let email = readFile(getCurrentDir() / "docs" / "email-and-notifications.md")
    let adapters = readFile(getCurrentDir() / "docs" / "external-adapters.md")
    check jobs.contains("SQLite is local\ndurability, not a distributed broker")
    check jobs.contains("Do not\nclaim provider delivery guarantees")
    check email.contains("disposable\nwire endpoint before production")
    check email.contains("callback transport is a local/test boundary")
    check adapters.contains("local callback/in-memory adapter is not proof")

  test "release reviewer has one documentation consistency checklist":
    let guide = readFile(getCurrentDir() / "docs" /
      "documentation-maintenance.md")
    check guide.contains("## 릴리스 전 문서 검토 체크리스트")
    for item in ["지원 매트릭스", "CHANGELOG.md", "문서 인덱스",
                 "실행 예제", "nimble docsCheck", "provider·배포 제한"]:
      check guide.contains(item)

  test "release guide makes every qualification command and recovery actionable":
    let guide = readFile(getCurrentDir() / "docs" / "release-guide.md")
    for command in ["nimble check", "nimble test", "nimble verify",
                    "nimble planStatus", "git diff --check",
                    "nimble releaseManifest"]:
      check guide.contains(command)
    for detail in ["MAHANAIM_RELEASE_MANIFEST", "MAHANAIM_RELEASE_ARTIFACTS",
                   "명시적 skip", "실패하면 qualification을 중단"]:
      check guide.contains(detail)

  test "operations deployment and adoption guides name their canonical scopes":
    let operations = readFile(getCurrentDir() / "docs" / "operations-guide.md")
    let recipes = readFile(getCurrentDir() / "docs" / "deployment-recipes.md")
    let adoption = readFile(getCurrentDir() / "docs" / "adoption-and-release.md")
    check operations.contains("[배포 레시피](deployment-recipes.md)")
    check operations.contains("[도입과 릴리스](adoption-and-release.md)")
    check recipes.contains("[operations guide](operations-guide.md)")
    check recipes.contains("[adoption and release guide](adoption-and-release.md)")
    check adoption.contains("[배포 레시피](deployment-recipes.md)")
    check adoption.contains("[운영 가이드](operations-guide.md)")

  test "operators can follow observability and deployment verification steps":
    let observability = readFile(getCurrentDir() / "docs" / "observability.md")
    let recipes = readFile(getCurrentDir() / "docs" / "deployment-recipes.md")
    for command in ["curl --fail http://127.0.0.1:8000/health",
                    "curl --fail http://127.0.0.1:8000/ready",
                    "curl --fail http://127.0.0.1:8000/metrics"]:
      check observability.contains(command)
    check observability.contains("[배포 레시피](deployment-recipes.md)")
    check recipes.contains("docker compose -f deploy/docker-compose.yml up -d")
    check recipes.contains("sudo systemctl enable --now mahanaim.service")

  test "model documentation names sensitive relation transaction and isolation evidence":
    let models = readFile(getCurrentDir() / "docs" / "models-and-metadata.md")
    let database = readFile(getCurrentDir() / "docs" / "database-connections.md")
    let coreTests = readFile(getCurrentDir() / "tests" / "test_core.nim")
    check models.contains("sensitive fields must stay excluded")
    check models.contains("choose relation loading")
    check database.contains("transaction\nrollback")
    check database.contains("지원하지 않는 isolation")
    check coreTests.contains("metadata serializer renames fields and excludes sensitive values")
    check coreTests.contains("database repository eager-loads one-hop nested relations")
    check coreTests.contains("session.setIsolationLevel(isolationSerializable)")

  test "security guide maps denial examples to executable contracts":
    let guide = readFile(getCurrentDir() / "docs" / "security.md")
    let coreTests = readFile(getCurrentDir() / "tests" / "test_core.nim")
    for contract in ["authorization policy composes roles groups object checks and route guards",
                     "security policy issues and validates signed CSRF tokens",
                     "security policy applies an application-wide fixed-window rate limit"]:
      check guide.contains(contract)
      check coreTests.contains(contract)
    check guide.contains("`403`")
    check guide.contains("`429`")

  test "API guide request and response schema map to OpenAPI contracts":
    let guide = readFile(getCurrentDir() / "docs" / "api-development.md")
    let coreTests = readFile(getCurrentDir() / "tests" / "test_core.nim")
    check guide.contains("requestSchema: @[integerField(\"id\", flPath)]")
    check guide.contains("responseSchema: @[stringField(\"name\", flBody)]")
    check guide.contains("app.addDocumentedRoute(registry, operation, getProduct)")
    check coreTests.contains("OpenAPI document projects a typed response schema")
    check coreTests.contains("documented route registration keeps router and OpenAPI registry aligned")

  test "negotiation and upload guides map rejection paths to executable contracts":
    let responses = readFile(getCurrentDir() / "docs" /
      "responses-and-negotiation.md")
    let uploads = readFile(getCurrentDir() / "docs" / "uploads.md")
    let coreTests = readFile(getCurrentDir() / "tests" / "test_core.nim")
    check responses.contains("406 `Not Acceptable`")
    check responses.contains("Vary: Accept")
    check uploads.contains("UploadValidationError")
    check uploads.contains("problemResponse(Http400, \"Upload rejected\"")
    check coreTests.contains("response negotiation honors Accept quality and q zero")
    check coreTests.contains("upload storage validates and saves multipart files safely")
    check coreTests.contains("malformed multipart body returns a body-scoped validation issue")
  test "repository checklist contains the required evidence sections":
    let issues = validateDefinitionOfDone(getCurrentDir() / "docs" /
      "definition-of-done.md")
    check issues.len == 0
    check validatePlanChecklist(getCurrentDir() / "plan.md").len == 0

  test "malformed checklist reports every missing contract":
    let path = getTempDir() / "mahanaim-definition-of-done-invalid.md"
    writeFile(path, """
## 기능 단위 체크리스트
- [X] malformed marker
## 검증 게이트
nimble test
## 상태 표기 규칙
""")
    defer:
      if fileExists(path):
        removeFile(path)
    let issues = validateDefinitionOfDone(path)
    check issues.len >= 2
    check issues.anyIt(it.contains("verification command is missing"))
    check issues.anyIt(it.contains("checkbox marker is invalid"))

  test "malformed implementation plan reports invalid status and empty item":
    let path = getTempDir() / "mahanaim-plan-invalid.md"
    writeFile(path, """
## 현재 실행 큐
- [X] invalid marker
- [ ]
## 완료 판정
""")
    defer:
      if fileExists(path):
        removeFile(path)
    let issues = validatePlanChecklist(path)
    check issues.anyIt(it.contains("checkbox marker is invalid"))
    check issues.anyIt(it.contains("checklist item is empty"))

  test "implementation plan status summary counts each supported marker":
    let path = getTempDir() / "mahanaim-plan-summary.md"
    writeFile(path, """
## ?꾩옱 ?ㅽ뻾 ??
- [x] completed foundation
- [-] partial live boundary
- [ ] pending external evidence
## ?꾨즺 ?먯젙
""")
    defer:
      if fileExists(path):
        removeFile(path)
    let summary = summarizePlanChecklist(path)
    check summary.completed == 1
    check summary.partial == 1
    check summary.pending == 1

  test "planStatus is wired as a repeatable planning gate":
    ## The summary API is useful only if maintainers can run it without
    ## writing a custom Nim program. Keep the executable and task discoverable
    ## beside the other repository-owned verification gates.
    let tool = getCurrentDir() / "tools" / "plan_status.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let source = readFile(tool)
    check fileExists(tool)
    check manifest.contains("task planStatus")
    check manifest.contains("tools/plan_status.nim")
    check source.contains("completed=")
    check source.contains("partial=")
    check source.contains("pending=")

  test "router benchmark is wired as a repeatable Nimble gate":
    let benchmark = getCurrentDir() / "benchmarks" / "router_benchmark.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(benchmark)
    check manifest.contains("task routerBenchmark")
    check manifest.contains("benchmarks/router_benchmark.nim")

  test "ORM query benchmark is wired as a repeatable Nimble gate":
    ## Query compilation is a framework-owned performance boundary. Keep its
    ## executable and gate discoverable so SQL/compiler regressions can be
    ## compared without turning machine-specific latency into a correctness
    ## threshold.
    let benchmark = getCurrentDir() / "benchmarks" /
      "database_query_benchmark.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(benchmark)
    check manifest.contains("task databaseQueryBenchmark")
    check manifest.contains("benchmarks/database_query_benchmark.nim")

  test "serialization benchmark is wired as a repeatable Nimble gate":
    ## Metadata serialization is a separate framework boundary from query
    ## compilation. Keep its deterministic executable and gate explicit so
    ## serializer regressions are measured without a database or HTTP server.
    let benchmark = getCurrentDir() / "benchmarks" /
      "serialization_benchmark.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(benchmark)
    check manifest.contains("task serializationBenchmark")
    check manifest.contains("benchmarks/serialization_benchmark.nim")

  test "template benchmark is wired as a repeatable Nimble gate":
    ## Template rendering has its own AST, escaping, and loop-context costs.
    ## Keep the workload separate from serializer and transport benchmarks.
    let benchmark = getCurrentDir() / "benchmarks" /
      "template_benchmark.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(benchmark)
    check manifest.contains("task templateBenchmark")
    check manifest.contains("benchmarks/template_benchmark.nim")

  test "HTTP dispatch benchmark is wired as a repeatable Nimble gate":
    ## Dispatch is the framework-owned HTTP workload; socket and production
    ## network latency belong to the separate live-server gates.
    let benchmark = getCurrentDir() / "benchmarks" /
      "http_dispatch_benchmark.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(benchmark)
    check manifest.contains("task httpDispatchBenchmark")
    check manifest.contains("benchmarks/http_dispatch_benchmark.nim")

  test "password benchmark exposes an isolated concurrent-load mode":
    ## Sequential KDF latency cannot reveal the memory pressure of concurrent
    ## login verification. Keep the process boundary explicit so each worker
    ## owns its hasher and the benchmark cannot accidentally share mutable
    ## application state.
    let benchmark = getCurrentDir() / "benchmarks" /
      "password_hash_benchmark.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let guide = readFile(getCurrentDir() / "docs" / "operations-guide.md")
    let source = readFile(benchmark)
    check fileExists(benchmark)
    check manifest.contains("task passwordBenchmark")
    check manifest.contains("benchmarks/password_hash_benchmark.nim")
    check source.contains("--concurrency=")
    check source.contains("startProcess")
    check source.contains("--worker")
    check guide.contains("--concurrency")
    check guide.contains("concurrent wall 1927 ms")

  test "detailed implementation plan records the latest Redis live evidence":
    ## Keep the detailed plan aligned with the repository checklist: local
    ## service evidence may be complete while production rollout evidence is
    ## deliberately retained as a partial item.
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check implementationPlan.contains("2026-08-06 — Redis live evidence reconciliation")
    check implementationPlan.contains("Redis 7.2.15")
    check implementationPlan.contains("Production Redis/Valkey rollout evidence remains")

  test "API stability policy matches the package manifest":
    ## The manifest declares the installable dependency boundary while the
    ## policy explains compatibility promises. Keep both machine-checkable so
    ## a release cannot silently change one without updating the other.
    let policyPath = getCurrentDir() / "docs" /
      "api-stability-policy.md"
    let policy = readFile(policyPath)
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let supportMatrix = readFile(getCurrentDir() / "docs" /
      "support-matrix.md")
    check fileExists(policyPath)
    check policy.contains("Semantic versioning")
    check policy.contains("experimental")
    check policy.contains("deprecated")
    check policy.contains("migration guide")
    check policy.contains("Security release")
    check manifest.contains("version       = \"0.1.0\"")
    check manifest.contains("requires \"nim >= 2.2.0\"")
    check manifest.contains("requires \"prologue >= 0.6.8\"")
    check policy.contains("SQLite")
    check policy.contains("PostgreSQL")
    check supportMatrix.contains("Nim")
    check supportMatrix.contains("macOS")

  test "support matrix keeps every first-party feature and its evidence machine-checkable":
    ## The table is deliberately compact enough for this parser: a future
    ## feature cannot be presented as supported without a maturity label,
    ## target boundary, and repeatable command or retained live evidence.
    let readme = readFile(getCurrentDir() / "README.md")
    let matrix = readFile(getCurrentDir() / "docs" / "support-matrix.md")
    let policy = readFile(getCurrentDir() / "docs" / "support-policy.md")
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let features = [
      "application-routing", "dependency-injection", "typed-api-openapi",
      "sqlite-storage", "postgresql-adapter", "admin-forms",
      "authentication-security", "email-notifications", "background-jobs",
      "http-transport", "storage-cache-rate-limit", "realtime-events",
      "observability-testing-cli"
    ]
    check readme.contains("MIT License")
    check manifest.contains("license       = \"MIT\"")
    check matrix.contains("| feature | maturity | supported targets | evidence |")
    for feature in features:
      let rows = matrix.splitLines.filterIt(it.startsWith("| " & feature & " |"))
      check rows.len == 1
      if rows.len == 1:
        let columns = rows[0].split('|').mapIt(it.strip())
        check columns.len == 6
        check columns[2] in ["experimental", "stable", "deprecated"]
        check columns[3].len > 0
        check columns[4].len > 0
    check policy.contains("Evidence promotion policy")
    check policy.contains("release artifact")

  test "every support-matrix feature links to a user guide":
    ## The matrix is the source of truth for feature maturity; this companion
    ## map makes its user documentation discoverable and rejects a feature row
    ## that has evidence but no explanation of how to use its boundary.
    let matrix = readFile(getCurrentDir() / "docs" / "support-matrix.md")
    let features = [
      "application-routing", "dependency-injection", "typed-api-openapi",
      "sqlite-storage", "postgresql-adapter", "admin-forms",
      "authentication-security", "email-notifications", "background-jobs",
      "http-transport", "storage-cache-rate-limit", "realtime-events",
      "observability-testing-cli"
    ]
    for feature in features:
      let rows = matrix.splitLines.filterIt(it.startsWith("| `" & feature & "` |"))
      check rows.len == 1
      if rows.len == 1:
        check localMarkdownTargets(rows[0]).len > 0

  test "minimal documentation example has a compile and run gate":
    ## The smallest public example must exercise the same Application route
    ## and dispatch contract that users see in the documentation.
    let example = getCurrentDir() / "examples" / "minimal_app.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(example)
    check manifest.contains("task docsExamples")
    check manifest.contains("examples/minimal_app.nim")
    let readme = readFile(getCurrentDir() / "README.md")
    check readme.contains("## 실행 예제")
    check readme.contains("[" & "`" & "minimal_app.nim" & "`" &
      "](examples/minimal_app.nim)")
    check readme.contains("`nimble docsExamples`")
    check readme.contains("`minimal-app-ok`")

  test "README gives a new user one-screen install scaffold test and next path":
    let readme = readFile(getCurrentDir() / "README.md")
    for command in ["nimble install", "nimble build",
                    ".\\mahanaim_cli.exe new shop ./shop", "nimble test",
                    "nimble run -- dev"]:
      check readme.contains(command)
    for guide in ["docs/getting-started.md", "docs/project-layout.md",
                  "docs/cli-reference.md", "docs/feature-map.md",
                  "docs/operations-guide.md"]:
      check readme.contains("](" & guide & ")")

  test "README reaches first request feature API CLI and operations guides directly":
    let readme = readFile(getCurrentDir() / "README.md")
    check readme.contains("examples/minimal_app.nim")
    for guide in ["docs/feature-map.md", "docs/api-reference/README.md",
                  "docs/cli-reference.md", "docs/operations-guide.md"]:
      check readme.contains("](" & guide & ")")

  test "CI fails pull requests when documentation contracts or examples drift":
    let workflow = readFile(getCurrentDir() / ".github" / "workflows" /
      "ci.yml")
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check workflow.contains("run: nimble verify")
    check workflow.contains("run: nimble docsCheck")
    check manifest.contains("task docsExamples")
    check manifest.contains("exec \"nimble docsCheck\"")
    check manifest.contains("exec \"nimble docsExamples\"")
    check readFile(getCurrentDir() / "docs" / "support-matrix.md").contains(
      "## 기능 문서 연결")

  test "documentation gates do not require external provider credentials":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let examplesStart = manifest.find("task docsExamples")
    let examplesEnd = manifest.find("task publicApiCheck", examplesStart)
    check examplesStart >= 0
    check examplesEnd > examplesStart
    let examplesTask = manifest[examplesStart ..< examplesEnd]
    for externalName in ["postgres", "redis", "https", "releaseManifest"]:
      check not examplesTask.toLowerAscii().contains(externalName.toLowerAscii())
    for skip in ["PostgreSQL live test skipped: credentials are not configured",
                 "Redis/Valkey live test skipped: connection settings are not configured",
                 "HTTPS live test skipped: MAHANAIM_HTTPS_URL is not configured"]:
      check manifest.contains(skip)

  test "external provider examples document disposable settings and safe skips":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let workflow = readFile(getCurrentDir() / ".github" / "workflows" /
      "ci.yml")
    let postgres = readFile(getCurrentDir() / "docs" / "postgresql.md")
    let operations = readFile(getCurrentDir() / "docs" / "operations-guide.md")
    for variable in ["MAHANAIM_POSTGRES_USER", "MAHANAIM_POSTGRES_PASSWORD",
                     "MAHANAIM_POSTGRES_DATABASE"]:
      check postgres.contains(variable)
    check postgres.contains("disposable test database")
    check postgres.contains("명시적인 skip")
    for detail in ["MAHANAIM_REDIS_HOST", "MAHANAIM_REDIS_PORT",
                   "disposable or staging Redis/Valkey service",
                   "nimble redisLive"]:
      check operations.contains(detail)
    check manifest.contains("PostgreSQL live test skipped")
    check manifest.contains("Redis/Valkey live test skipped")
    check workflow.contains("MAHANAIM_POSTGRES_DATABASE")

  test "README catalogs every executable example with its expected result":
    let readme = readFile(getCurrentDir() / "README.md")
    for example in ["minimal_app", "local_storage", "api_artifacts",
                    "plugin_extension", "admin_audit", "admin_templates",
                    "template_form_htmx", "sqlite_crud_migration",
                    "jobs_realtime_channels"]:
      check readme.contains("examples/" & example & ".nim")
    for result in ["minimal-app-ok", "local-storage-ok", "api-artifacts-ok",
                   "plugin-extension-ok", "admin-audit-ok", "admin-templates-ok",
                   "template-form-htmx-ok", "sqlite-crud-migration-ok",
                   "jobs-realtime-channels-ok"]:
      check readme.contains(result)

  test "jobs realtime and channel guides link one credential-free example":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let example = readFile(getCurrentDir() / "examples" /
      "jobs_realtime_channels.nim")
    check manifest.contains("examples/jobs_realtime_channels.nim")
    check example.contains("jobs-realtime-channels-ok")
    check example.contains("newSqliteDurableJobStore")
    check example.contains("getSseEvents")
    check example.contains("connectWebSocket")
    check example.contains("newInMemoryChannelLayer")
    check example.contains("newRedisChannelLayer")
    for guide in ["background-jobs.md", "websocket.md", "sse.md",
                  "channel-layers.md"]:
      check readFile(getCurrentDir() / "docs" / guide).contains(
        "examples/jobs_realtime_channels.nim")

  test "SQLite CRUD migration tutorial and PostgreSQL limits are discoverable":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let tutorial = readFile(getCurrentDir() / "docs" /
      "sqlite-crud-migration-tutorial.md")
    let postgres = readFile(getCurrentDir() / "docs" / "postgresql.md")
    let migrations = readFile(getCurrentDir() / "docs" / "migrations.md")
    let example = readFile(getCurrentDir() / "examples" /
      "sqlite_crud_migration.nim")
    check manifest.contains("examples/sqlite_crud_migration.nim")
    check example.contains("sqlite-crud-migration-ok")
    check tutorial.contains("metadata를 선언하고 migration을 적용")
    check tutorial.contains("newDatabaseRepository")
    check tutorial.contains("rollback")
    check postgres.contains("MAHANAIM_POSTGRES_USER")
    check postgres.contains("nimble postgresLive")
    check postgres.contains("experimental")
    check migrations.contains("sqlite-crud-migration-tutorial.md")
    check migrations.contains("postgresql.md")

  test "local storage example is executable without provider credentials":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let example = readFile(getCurrentDir() / "examples" / "local_storage.nim")
    let staticGuide = readFile(getCurrentDir() / "docs" / "static-assets.md")
    let uploadsGuide = readFile(getCurrentDir() / "docs" / "uploads.md")
    check manifest.contains("examples/local_storage.nim")
    check example.contains("local-storage-ok")
    check example.contains("ttlSeconds = 60")
    check staticGuide.contains("examples/local_storage.nim")
    check uploadsGuide.contains("examples/local_storage.nim")

  test "OpenAPI JSON and TypeScript artifacts have an executable example":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let example = readFile(getCurrentDir() / "examples" / "api_artifacts.nim")
    let apiGuide = readFile(getCurrentDir() / "docs" / "api-development.md")
    let openApiGuide = readFile(getCurrentDir() / "docs" / "openapi.md")
    check manifest.contains("examples/api_artifacts.nim")
    check example.contains("api-artifacts-ok")
    check example.contains("app.runCli([\"openapi\"")
    check example.contains("app.runCli([\"openapi-ts\"")
    check apiGuide.contains("examples/api_artifacts.nim")
    check openApiGuide.contains("examples/api_artifacts.nim")

  test "plugin extension example covers route service and manifest failures":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let example = readFile(getCurrentDir() / "examples" / "plugin_extension.nim")
    let pluginsGuide = readFile(getCurrentDir() / "docs" / "plugins.md")
    let extensionGuide = readFile(getCurrentDir() / "docs" / "extension-authoring.md")
    check manifest.contains("examples/plugin_extension.nim")
    check example.contains("plugin-extension-ok")
    check example.contains("app.provide(\"example.greeting\"")
    check example.contains("app.get(\"/plugin-greeting\"")
    check example.contains("resolvePluginManifests")
    check pluginsGuide.contains("examples/plugin_extension.nim")
    check extensionGuide.contains("examples/plugin_extension.nim")

  test "Admin example verifies authorization CRUD and audit events":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let example = readFile(getCurrentDir() / "examples" / "admin_audit.nim")
    let guide = readFile(getCurrentDir() / "docs" / "admin.md")
    check manifest.contains("examples/admin_audit.nim")
    check example.contains("admin-audit-ok")
    check example.contains("denied.status == Http403")
    check example.contains("created.status == Http201")
    check example.contains("formUpdate")
    check example.contains("formDelete")
    check example.contains("Http302")
    check example.contains("events[0].actor == \"admin-1\"")
    check guide.contains("examples/admin_audit.nim")

  test "Admin template override and legacy layout example is executable":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let example = readFile(getCurrentDir() / "examples" / "admin_templates.nim")
    let guide = readFile(getCurrentDir() / "docs" /
      "admin-template-customization.md")
    check manifest.contains("examples/admin_templates.nim")
    check example.contains("admin-templates-ok")
    check example.contains("resource-list")
    check example.contains("global-list")
    check example.contains("legacy-layout")
    check guide.contains("examples/admin_templates.nim")

  test "template form and HTMX example runs through one application":
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    let example = readFile(getCurrentDir() / "examples" / "template_form_htmx.nim")
    let formsGuide = readFile(getCurrentDir() / "docs" / "forms.md")
    let htmxGuide = readFile(getCurrentDir() / "docs" / "htmx.md")
    check manifest.contains("examples/template_form_htmx.nim")
    check example.contains("template-form-htmx-ok")
    check example.contains("htmlJsonResponse")
    check example.contains("bindForm")
    check example.contains("HX-Request")
    check formsGuide.contains("examples/template_form_htmx.nim")
    check htmxGuide.contains("examples/template_form_htmx.nim")

  test "public API compile contract is wired into verify":
    ## The root package export surface needs an explicit compile gate in
    ## addition to the large runtime contract suite.
    let contract = getCurrentDir() / "tests" /
      "test_public_api_compile.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(contract)
    check manifest.contains("task publicApiCheck")
    check manifest.contains("test_public_api_compile.nim")
    check manifest.contains("exec \"nimble publicApiCheck\"")

  test "every umbrella export has one support-matrix and guide mapping":
    ## Re-exporting a module makes its `*` symbols public to `import mahanaim`.
    ## A future module must therefore name both its maturity owner and a
    ## canonical guide, rather than silently expanding the public surface.
    let root = getCurrentDir()
    let mapping = readFile(root / "docs" / "api-reference" /
      "public-modules.md")
    let matrix = readFile(root / "docs" / "support-matrix.md")
    for moduleName in publicEntryPointModules(root):
      let rows = mapping.splitLines.filterIt(
        it.startsWith("| `" & moduleName & "` | `"))
      check rows.len == 1
      if rows.len == 1:
        let columns = rows[0].split('|').mapIt(it.strip())
        check columns.len == 6
        if columns.len == 6:
          let feature = columns[2].strip(chars = {'`'})
          check matrix.contains("| " & feature & " |")
          check localMarkdownTargets(rows[0]).len == 1

  test "database adapter contract is shared by SQLite and PostgreSQL fixtures":
    ## Keep backend-neutral semantics in one helper while each fixture owns
    ## its connection lifecycle and optional live credentials.
    let contract = getCurrentDir() / "tests" / "database_contracts.nim"
    let sqliteSuite = readFile(getCurrentDir() / "tests" / "test_core.nim")
    let postgresSuite = readFile(getCurrentDir() / "tests" /
      "test_postgres_live.nim")
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check fileExists(contract)
    check sqliteSuite.contains("runCommonDatabaseContract")
    check postgresSuite.contains("runCommonDatabaseContract")
    check implementationPlan.contains("tests/database_contracts.nim")

  test "security negative-path evidence is recorded in the implementation plan":
    let coreSuite = readFile(getCurrentDir() / "tests" / "test_core.nim")
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check coreSuite.contains("untrusted forwarded host cannot bypass host allow list")
    check implementationPlan.contains("untrusted forwarded host")

  test "release policy requirements are marked complete only with policy artifacts":
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    let policy = readFile(getCurrentDir() / "docs" /
      "api-stability-policy.md")
    let supportMatrix = readFile(getCurrentDir() / "docs" /
      "support-matrix.md")
    check implementationPlan.contains(
      "- [x] 코어 계약과 adapter API를 분리해 semantic versioning")
    check implementationPlan.contains("- [x] 지원 Nim 버전, Prologue adapter 버전")
    check implementationPlan.contains("- [x] deprecated API는 최소 한 주기")
    check implementationPlan.contains("- [x] 기능 성숙도는 `experimental`")
    check implementationPlan.contains("- [x] 보안 수정은 별도 changelog")
    check policy.contains("Semantic versioning")
    check policy.contains("Deprecation and migration guide")
    check policy.contains("Security release")
    check supportMatrix.contains("Nim")

  test "migration plan records concurrent SQLite evidence":
    let coreSuite = readFile(getCurrentDir() / "tests" / "test_core.nim")
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check coreSuite.contains(
      "SQLite migration is idempotent across concurrent connections")
    check implementationPlan.contains("동시 요청 조건에서 검증한다")

  test "PostgreSQL live migration contract includes concurrent connections":
    let liveSuite = readFile(getCurrentDir() / "tests" /
      "test_postgres_live.nim")
    let adapter = readFile(getCurrentDir() / "src" / "mahanaim" /
      "postgres_adapter.nim")
    let guide = readFile(getCurrentDir() / "docs" /
      "operations-guide.md")
    check liveSuite.contains("runLiveConcurrentMigrationContract")
    check liveSuite.contains("PostgreSQL concurrent migration history")
    check adapter.contains("pg_advisory_xact_lock")
    check guide.contains("two independent PostgreSQL connections")

  test "direct httpx deployment adapter has an explicit compile gate":
    let adapter = getCurrentDir() / "src" / "mahanaim" / "httpx_adapter.nim"
    let contract = getCurrentDir() / "tests" /
      "test_httpx_adapter_compile.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(adapter)
    check fileExists(contract)
    check manifest.contains("task httpxCheck")
    check manifest.contains("test_httpx_adapter_compile.nim")

  test "Redis ChannelLayer rolling runbook names drain and rollback evidence":
    let guide = readFile(getCurrentDir() / "docs" / "operations-guide.md")
    check guide.contains("Redis ChannelLayer rolling deployment runbook")
    check guide.contains("reconnectWithRetry")
    check guide.contains("shutdown")
    check guide.contains("readiness")
    check guide.contains("rollback")
    check guide.contains("nimble redisLive")

  test "implementation plan distinguishes local adapter baselines from live evidence":
    ## The implementation plan is also a maintenance boundary: it must not
    ## describe already-tested local adapters as entirely unimplemented, while
    ## retaining the provider-specific signing and deployment evidence that
    ## still belongs to an application-owned environment.
    let plan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check not plan.contains("object-storage backend와 WebSocket adapter는 남아 있다.")
    check plan.contains("[x] HTML·JSON·upload·WebSocket route를 같은 앱에서 실행한다.")
    check not plan.contains("OpenAPI UI와 WebSocket/SSE 고급 확장은 후속 설계 항목이다.")
    check plan.contains("S3 signing/retry와 별도 cache eviction 부하 운영 정책은 남아 있다.")

  test "template adapter baseline is documented as an extension boundary":
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    let requirements = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-requirements.md")
    check implementationPlan.contains("TemplateAdapter")
    check implementationPlan.contains("alternate template engine")
    check requirements.contains("TemplateAdapter")

  test "storage and ORM integration patterns are documented":
    ## Storage and ORM integrations are intentionally adapter-owned. This
    ## contract keeps the usage guide discoverable and prevents future edits
    ## from silently coupling application code to a provider SDK or ORM.
    let guidePath = getCurrentDir() / "docs" /
      "storage-and-orm-integration.md"
    let guide = readFile(guidePath)
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check fileExists(guidePath)
    check guide.contains("ObjectStorage and CacheStore")
    check guide.contains("DatabaseRepository")
    check guide.contains("external ORM integration")
    check guide.contains("Framework-owned contract")
    check guide.contains("nimble test")
    check implementationPlan.contains(
      "- [x] Redis/Valkey/file/memory store")
    check implementationPlan.contains("docs/storage-and-orm-integration.md")

  test "model database and query guides link the storage ORM ownership boundary":
    let models = readFile(getCurrentDir() / "docs" / "models-and-metadata.md")
    let database = readFile(getCurrentDir() / "docs" / "database-connections.md")
    let querying = readFile(getCurrentDir() / "docs" / "querying.md")
    let integration = readFile(getCurrentDir() / "docs" /
      "storage-and-orm-integration.md")
    for guide in [models, database, querying]:
      check guide.contains("storage-and-orm-integration.md")
    check integration.contains("ExternalOrmBridge")
    check integration.contains("closeSession")
    check integration.contains("application-owned 외부 ORM adapter")

  test "foundation checklist records the implemented core boundaries":
    ## These are repository-owned contracts, so their status must follow the
    ## public modules and repeatable tests rather than remain a stale roadmap
    ## placeholder after the vertical slices have landed.
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check implementationPlan.contains("- [x] **계약 우선**")
    check implementationPlan.contains("- [x] **단일 메타데이터 원천**")
    check implementationPlan.contains("- [x] **명시적 실행 경계**")
    check implementationPlan.contains("- [x] **Prologue 비종속 코어**")
    check implementationPlan.contains("- [x] `Application`, `Config`, `RequestContext`")
    check implementationPlan.contains("- [x] Prologue adapter를 격리하고")
    check implementationPlan.contains("- [x] router, route name/URL building")

  test "implementation plan records lifecycle extension integration":
    ## Lifecycle registration is a framework-owned invariant. The detailed
    ## plan must reflect the shipped guard rather than leave a stale open item
    ## that suggests plugins may mutate a running application.
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check implementationPlan.contains(
      "- [x] command/admin extension의 lifecycle integration")
    check implementationPlan.contains("startup 전용 registration window")

  test "implementation plan separates local job contracts from provider evidence":
    ## The repository owns bounded background-job and external-store protocols;
    ## queue provider visibility/ack behavior belongs to an application-owned
    ## deployment. Keep that distinction explicit in the roadmap.
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check implementationPlan.contains(
      "- [-] request lifecycle과 분리된 `BackgroundJobQueue`")
    check implementationPlan.contains("외부 queue provider protocol")

  test "implementation plan distinguishes unsupported native cancellation":
    ## Cooperative cancellation is a shipped contract; arbitrary native
    ## worker termination is intentionally unsupported without a safe backend
    ## primitive. The roadmap must preserve that safety boundary explicitly.
    let implementationPlan = readFile(getCurrentDir() / "docs" /
      "nim-fullstack-framework-implementation-plan.md")
    check implementationPlan.contains(
      "- [-] taskpools worker의 cooperative cancellation")
    check implementationPlan.contains(
      "- [x] Nim `taskpools`가 제공하지 않는 임의 native thread 강제 종료")

  test "release matrix declares the supported macOS runner boundary":
    ## The matrix is a source-level release contract. It must describe the
    ## runner before external GitHub evidence is collected, otherwise a green
    ## Linux/Windows job can silently omit a declared supported platform.
    let workflow = readFile(getCurrentDir() / ".github" / "workflows" /
      "ci.yml")
    let supportMatrix = readFile(getCurrentDir() / "docs" /
      "support-matrix.md")
    check workflow.contains("os: [ubuntu-latest, windows-latest, macos-latest]")
    check workflow.contains("name: macOS PostgreSQL client runtime")
    check workflow.contains("name: Upload release candidate and checksum")
    check supportMatrix.contains("macOS")
    check supportMatrix.contains("release matrix")

  test "CI records the implementation plan status before platform gates":
    ## The external runner evidence is only useful when the exact checklist
    ## state used by that run is visible in its log.
    let workflow = readFile(getCurrentDir() / ".github" / "workflows" /
      "ci.yml")
    check workflow.contains("name: Report implementation plan status")
    check workflow.contains("run: nimble planStatus")

  test "release matrix installs a platform-matching Nim archive":
    ## A Unix-only condition is not sufficient for a release matrix: Linux
    ## and macOS use different Nim archives. Keeping this invariant in the
    ## repository contract prevents a green workflow edit from masking a
    ## platform-specific bootstrap failure on the first macOS runner.
    let workflow = readFile(getCurrentDir() / ".github" / "workflows" /
      "ci.yml")
    check workflow.contains("name: Install Nim (Linux)")
    check workflow.contains("if: runner.os == 'Linux'")
    check workflow.contains("name: Install Nim (macOS)")
    check workflow.contains("if: runner.os == 'macOS'")
    check workflow.contains("nim-${{ matrix.nim }}-macosx_x64.tar.xz")
    check not workflow.contains("name: Install Nim (Unix)")

  test "release manifest runner uses the shared checksum boundary":
    let tool = getCurrentDir() / "tools" / "release_manifest.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(tool)
    check manifest.contains("task releaseManifest")
    check readFile(tool).contains("writeArtifactManifestForFiles")
    let workflow = readFile(getCurrentDir() / ".github" / "workflows" /
      "ci.yml")
    check workflow.contains("run: nimble releaseManifest")
    check workflow.contains("release-artifacts.manifest")

  test "deployment recipes define bounded graceful shutdown":
    ## Deployment files are templates for an application-owned binary. The
    ## contract test keeps their safety-critical process boundaries visible
    ## even when Docker/systemd are unavailable on a developer machine.
    let dockerfile = getCurrentDir() / "deploy" / "Dockerfile"
    let compose = getCurrentDir() / "deploy" / "docker-compose.yml"
    let nginx = getCurrentDir() / "deploy" / "nginx.conf"
    let systemd = getCurrentDir() / "deploy" / "mahanaim.service"
    let guide = getCurrentDir() / "docs" / "deployment-recipes.md"
    check fileExists(dockerfile)
    check fileExists(compose)
    check fileExists(nginx)
    check fileExists(systemd)
    check fileExists(guide)
    let dockerText = readFile(dockerfile)
    check dockerText.contains("AS build")
    check dockerText.contains("STOPSIGNAL SIGTERM")
    check dockerText.contains("USER mahanaim")
    check dockerText.contains("MAHANAIM_HOST")
    let composeText = readFile(compose)
    check composeText.contains("stop_grace_period")
    check composeText.contains("healthcheck")
    check composeText.contains("nginx")
    let nginxText = readFile(nginx)
    check nginxText.contains("proxy_set_header X-Forwarded-Proto")
    check nginxText.contains("proxy_read_timeout")
    let systemdText = readFile(systemd)
    check systemdText.contains("KillSignal=SIGTERM")
    check systemdText.contains("TimeoutStopSec=")
    check systemdText.contains("ExecStart=")
    let guideText = readFile(guide)
    check guideText.contains("docker compose")
    check guideText.contains("readiness")
    check guideText.contains("graceful shutdown")

  test "HTTPS local wire fixture is wired as a repeatable deployment gate":
    let script = getCurrentDir() / "tests" / "run_https_wire.ps1"
    let guide = readFile(getCurrentDir() / "docs" /
      "operations-guide.md")
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(script)
    check manifest.contains("task httpsLiveCheck")
    check manifest.contains("task httpsLive")
    check guide.contains("run_https_wire.ps1")
    check guide.contains("HTTPS reverse-proxy live contract passed")

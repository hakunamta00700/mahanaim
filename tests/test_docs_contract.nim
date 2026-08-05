## Definition of Done document contract.
##
## The checklist is a release input, not only prose. This test keeps its
## required sections and verification commands machine-checkable so a future
## edit cannot silently remove the evidence boundary from the framework.

import std/[os, sequtils, strutils, unittest]
import mahanaim

suite "definition of done contracts":
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

  test "minimal documentation example has a compile and run gate":
    ## The smallest public example must exercise the same Application route
    ## and dispatch contract that users see in the documentation.
    let example = getCurrentDir() / "examples" / "minimal_app.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(example)
    check manifest.contains("task docsExamples")
    check manifest.contains("examples/minimal_app.nim")

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

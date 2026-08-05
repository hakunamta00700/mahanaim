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

  test "router benchmark is wired as a repeatable Nimble gate":
    let benchmark = getCurrentDir() / "benchmarks" / "router_benchmark.nim"
    let manifest = readFile(getCurrentDir() / "mahanaim.nimble")
    check fileExists(benchmark)
    check manifest.contains("task routerBenchmark")
    check manifest.contains("benchmarks/router_benchmark.nim")

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

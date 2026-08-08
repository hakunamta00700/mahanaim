# Mahanaim framework package manifest.
# Keep the framework frontend small while application-owned commands remain
# explicit extension points.
import std/[os, strutils]

version       = "0.1.0"
author        = "Mahanaim contributors"
description   = "A low-magic full-stack web framework for Nim"
license       = "MIT"
srcDir        = "src"
## `srcDir` changes Nimble's installation root to `src`; whitelist that root
## itself so downstream projects receive every public source module.
installDirs   = @["."]
bin           = @[
  "mahanaim_cli"
]

requires "nim >= 2.2.0"
requires "nimcrypto >= 0.7.3"
requires "parsetoml >= 0.7.2"
requires "prologue >= 0.6.8"
requires "taskpools >= 0.1.0"
requires "db_connector >= 0.1.0"
requires "argon2 >= 1.1.0"
requires "checksums >= 0.2.2"
requires "timezones >= 0.5.4"
requires "httpx >= 0.3.8"

proc dependencyPathArgs(): string =
  ## Tasks are run by Nimble but invoke Nim directly, so pass every locked
  ## package path explicitly instead of depending on an ambient compiler path.
  let packageNames = "nimcrypto parsetoml prologue taskpools db_connector argon2 checksums timezones cookiejar httpx ioselectors " &
    "wepoll logue cligen regex unicodedb"
  let paths = staticExec("nimble path " & packageNames)
  for path in paths.splitLines:
    let normalized = path.strip()
    if normalized.len > 0:
      result.add(" --path:" & quoteShell(normalized))

task test, "Run the framework test suite":
  exec "nim c --path:src" & dependencyPathArgs() & " -r tests/test_core.nim"

task routerBenchmark, "Run the deterministic router benchmark":
  ## Keep performance measurements opt-in: correctness CI checks route
  ## invariants, while this gate gives maintainers one reproducible workload
  ## for comparing route-index changes without enforcing machine-specific
  ## latency thresholds.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r benchmarks/router_benchmark.nim"

task databaseQueryBenchmark, "Run the deterministic ORM query benchmark":
  ## Keep query compiler measurements separate from database-server latency;
  ## the executable validates SQL parameter binding for both supported dialects.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r benchmarks/database_query_benchmark.nim"

task serializationBenchmark, "Run the deterministic serialization benchmark":
  ## Measure metadata projection separately from database and transport work;
  ## each iteration also validates the default sensitive-field boundary.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r benchmarks/serialization_benchmark.nim"

task templateBenchmark, "Run the deterministic template benchmark":
  ## Keep template AST/render measurements independent from HTTP and database
  ## work; the executable validates escaping and loop metadata on each render.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r benchmarks/template_benchmark.nim"

task httpDispatchBenchmark, "Run the deterministic HTTP dispatch benchmark":
  ## Measure the core dispatch pipeline without conflating it with socket or
  ## deployment latency; live network behavior has its own contract gates.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r benchmarks/http_dispatch_benchmark.nim"

task docsExamples, "Compile and run executable documentation examples":
  ## Documentation drift is a release defect. Compile and execute the examples
  ## through the public package entry point on every local/CI gate.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/minimal_app.nim"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/local_storage.nim"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/api_artifacts.nim"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/plugin_extension.nim"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/admin_audit.nim"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/admin_templates.nim"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/template_form_htmx.nim"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/sqlite_crud_migration.nim"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r examples/jobs_realtime_channels.nim"

task publicApiCheck, "Compile the public package API contract":
  ## Compile-only catches removed exports and signature drift without hiding
  ## runtime semantics inside a static contract test.
  exec "nim c --compileOnly --path:src" & dependencyPathArgs() &
    " tests/test_public_api_compile.nim"

task check, "Compile the framework CLI":
  exec "nimble build"

task verify, "Compile the CLI and validate package contracts":
  exec "nimble build"
  exec "nimble lockCheck"
  exec "nimble docsCheck"
  exec "nimble docsExamples"
  exec "nimble publicApiCheck"

task docsCheck, "Validate the Definition of Done document contract":
  ## Keep checklist structure in the same verification path as source and
  ## dependency contracts; prose may still describe an incomplete item, but
  ## its evidence boundary must remain machine-readable.
  exec "nimble build"
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r tests/test_docs_contract.nim"

task planStatus, "Summarize implementation plan checklist status":
  ## Keep planning status available as a lightweight, repeatable repository
  ## gate. The repository task intentionally uses the canonical plan.md;
  ## embedding callers can pass another path to summarizePlanChecklist.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r tools/plan_status.nim"

task lockCheck, "Validate the checked-in dependency lockfile":
  ## Keep lock validation independent from package installation so a malformed
  ## lock is reported before the compiler starts a long dependency build.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r tests/test_lock_contract.nim"

task postgresCheck, "Compile the optional PostgreSQL adapter contract":
  ## Compile-only avoids requiring libpq.dll or a running PostgreSQL server.
  exec "nim c --compileOnly --path:src" & dependencyPathArgs() &
    " tests/test_postgres_adapter_compile.nim"

task postgresLiveCheck, "Compile the optional PostgreSQL live contract test":
  ## Keep the live test source checked even on developer machines without
  ## PostgreSQL credentials; execution remains the responsibility of CI or an
  ## explicitly configured local environment.
  exec "nim c --compileOnly --path:src" & dependencyPathArgs() &
    " tests/test_postgres_live.nim"

task postgresLive, "Run the optional PostgreSQL live contract test":
  ## The test exits successfully with an explicit skip when credentials are
  ## absent, while credentialed CI environments execute the real connection.
  if getEnv("MAHANAIM_POSTGRES_USER").len == 0 or
      getEnv("MAHANAIM_POSTGRES_PASSWORD").len == 0 or
      getEnv("MAHANAIM_POSTGRES_DATABASE").len == 0:
    echo "PostgreSQL live test skipped: credentials are not configured"
  else:
    exec "nim c --path:src" & dependencyPathArgs() &
      " -r tests/test_postgres_live.nim"

task redisLiveCheck, "Compile the optional Redis/Valkey live contract test":
  ## Keep the matrix source checked even when no local Redis service exists.
  exec "nim c --compileOnly --path:src" & dependencyPathArgs() &
    " tests/test_redis_live.nim"

task redisLive, "Run the optional Redis/Valkey live contract test":
  ## CI or a matrix runner supplies the host and port for one Redis-compatible
  ## service at a time; missing settings produce an explicit successful skip.
  if getEnv("MAHANAIM_REDIS_HOST").len == 0 or
      getEnv("MAHANAIM_REDIS_PORT").len == 0:
    echo "Redis/Valkey live test skipped: connection settings are not configured"
  else:
    exec "nim c --path:src" & dependencyPathArgs() &
      " -r tests/test_redis_live.nim"

task beastCheck, "Compile the non-Windows Beast/httpx adapter contract":
  ## The live server requires a Linux runner; compileOnly still catches
  ## overload drift and ownership API changes before that fixture is added.
  exec "nim c --compileOnly --path:src" & dependencyPathArgs() &
    " tests/test_beast_adapter_compile.nim"

task httpxCheck, "Compile the direct httpx deployment adapter contract":
  ## Keep the direct backend surface type-checked independently from the
  ## Prologue bridge; Windows imports the conditional module and Linux checks
  ## the actual httpx request/server types.
  exec "nim c --compileOnly --path:src" & dependencyPathArgs() &
    " tests/test_httpx_adapter_compile.nim"

task httpxTest, "Run the direct httpx deployment adapter contract":
  ## Runtime validation is small and binding-free; Linux live socket ownership
  ## remains the responsibility of the dedicated backend/deployment fixture.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r tests/test_httpx_adapter_compile.nim"

task bcryptCheck, "Compile the optional bcrypt password hasher contract":
  ## Keep the algorithm-specific acceptance contract behind its own gate so
  ## changes to the password boundary remain easy to diagnose.
  exec "nim c --compileOnly --path:src" & dependencyPathArgs() &
    " tests/test_bcrypt_contract.nim"

task bcryptTest, "Run the optional bcrypt password hasher contract":
  ## A small work factor keeps the correctness fixture deterministic and fast;
  ## production work-factor selection remains the benchmark's responsibility.
  exec "nim c --path:src" & dependencyPathArgs() &
    " -r tests/test_bcrypt_contract.nim"

task beastLiveCheck, "Compile the Linux Beast/httpx WebSocket wire fixture":
  ## Keep the fixture source in the normal gate so Linux CI catches API drift
  ## before attempting a network run.
  exec "nim c --path:src" & dependencyPathArgs() &
    " tests/test_beast_live.nim"

task beastLive, "Run the Linux Beast/httpx WebSocket wire fixture":
  ## The executable has server/client modes; the Linux runner orchestrates
  ## them separately so httpx's process-owned listener can be stopped safely.
  exec "sh tests/run_beast_live.sh"

task httpsLiveUpstream, "Compile the HTTPS reverse-proxy upstream fixture":
  ## The upstream is a real framework server; the TLS terminator remains an
  ## external proxy so this gate can exercise both ownership boundaries.
  exec "nim c --path:src" & dependencyPathArgs() &
    " tests/test_https_upstream.nim"

task httpsLiveCheck, "Compile the optional HTTPS wire contract":
  ## Keep the staging client source checked even when no endpoint is supplied.
  exec "nim c -d:ssl --compileOnly --path:src" & dependencyPathArgs() &
    " tests/test_https_live.nim"

task httpsLive, "Run the optional HTTPS reverse-proxy wire contract":
  ## A missing URL is an explicit safe skip; release automation should provide
  ## a trusted staging endpoint and leave insecure verification disabled.
  if getEnv("MAHANAIM_HTTPS_URL").len == 0:
    echo "HTTPS live test skipped: MAHANAIM_HTTPS_URL is not configured"
  else:
    exec "nim c -d:ssl --path:src" & dependencyPathArgs() &
      " -r tests/test_https_live.nim"

task benchmark, "Run deterministic router benchmark workloads":
  exec "nim c -d:release --path:src" & dependencyPathArgs() &
    " -r benchmarks/router_benchmark.nim"

task passwordBenchmark, "Measure password hashing on this machine":
  ## Production cost selection requires a release-like host and explicit
  ## settings; the executable's defaults mirror the adapter policy.
  exec "nim c -d:release --path:src" & dependencyPathArgs() &
    " -r benchmarks/password_hash_benchmark.nim"

task releaseManifest, "Generate a deterministic release artifact manifest":
  ## The artifact list and output path are supplied by the CI runner, while
  ## checksum calculation and ordering stay inside the shared framework API.
  if getEnv("MAHANAIM_RELEASE_MANIFEST").len == 0 or
      getEnv("MAHANAIM_RELEASE_ARTIFACTS").len == 0:
    echo "release manifest skipped: artifact environment is not configured"
  else:
    exec "nim c --path:src" & dependencyPathArgs() &
      " -r tools/release_manifest.nim"

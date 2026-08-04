# Mahanaim framework package manifest.
# Keep the framework frontend small while application-owned commands remain
# explicit extension points.
import std/[os, strutils]

version       = "0.1.0"
author        = "Mahanaim contributors"
description   = "A low-magic full-stack web framework for Nim"
license       = "MIT"
srcDir        = "src"
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
requires "timezones >= 0.5.4"

proc dependencyPathArgs(): string =
  ## Tasks are run by Nimble but invoke Nim directly, so pass every locked
  ## package path explicitly instead of depending on an ambient compiler path.
  let packageNames = "nimcrypto parsetoml prologue taskpools db_connector argon2 timezones cookiejar httpx ioselectors " &
    "wepoll logue cligen regex unicodedb"
  let paths = staticExec("nimble path " & packageNames)
  for path in paths.splitLines:
    let normalized = path.strip()
    if normalized.len > 0:
      result.add(" --path:" & quoteShell(normalized))

task test, "Run the framework test suite":
  exec "nim c --path:src" & dependencyPathArgs() & " -r tests/test_core.nim"

task check, "Compile the framework CLI":
  exec "nimble build"

task verify, "Compile the CLI and validate package contracts":
  exec "nimble build"

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

task passwordBenchmark, "Measure Argon2id password hashing on this machine":
  ## Production cost selection requires a release-like host and explicit
  ## settings; the executable's defaults mirror the adapter policy.
  exec "nim c -d:release --path:src" & dependencyPathArgs() &
    " -r benchmarks/password_hash_benchmark.nim"

## Argon2id password hashing benchmark.
##
## This executable deliberately lives outside the correctness suite. Password
## KDF costs are hardware- and deployment-specific, so a framework release
## must publish measured values instead of asserting a universal latency
## threshold in CI. The workload still validates every generated hash so a
## broken benchmark cannot report plausible-looking timing numbers.

import std/[os, strutils, monotimes, times]
import mahanaim/password_hashing

type
  BenchmarkOptions = object
    memoryKiB: uint32
    iterations: uint32
    threadCount: uint32
    derivedBytes: uint32
    samples: int

proc parseUintOption(argument, name: string, defaultValue: uint32): uint32 =
  ## Keep command-line parsing local to the benchmark; production application
  ## configuration should continue to use the framework's typed config API.
  if not argument.startsWith(name & "="):
    return defaultValue
  let raw = argument[(name.len + 1) .. ^1]
  try:
    parseUInt(raw).uint32
  except ValueError:
    raise newException(ValueError, "Invalid " & name & " value: " & raw)

proc parseOptions(): BenchmarkOptions =
  ## Defaults mirror the Argon2id adapter policy. Smaller values can be passed
  ## explicitly for a quick local smoke run, but those measurements must not
  ## be used as production security recommendations.
  result.memoryKiB = 64 * 1024
  result.iterations = 3
  result.threadCount = 1
  result.derivedBytes = 32
  result.samples = 5
  for argument in commandLineParams():
    if argument.startsWith("--memory-kib="):
      result.memoryKiB = parseUintOption(argument, "--memory-kib", result.memoryKiB)
    elif argument.startsWith("--iterations="):
      result.iterations = parseUintOption(argument, "--iterations", result.iterations)
    elif argument.startsWith("--threads="):
      result.threadCount = parseUintOption(argument, "--threads", result.threadCount)
    elif argument.startsWith("--derived-bytes="):
      result.derivedBytes = parseUintOption(argument, "--derived-bytes", result.derivedBytes)
    elif argument.startsWith("--samples="):
      let raw = argument[10 .. ^1]
      try:
        result.samples = parseInt(raw)
      except ValueError:
        raise newException(ValueError, "Invalid --samples value: " & raw)
    elif argument in ["--help", "-h"]:
      echo "Usage: password_hash_benchmark [--memory-kib=N] [--iterations=N] " &
        "[--threads=N] [--derived-bytes=N] [--samples=N]"
      quit(0)
    else:
      raise newException(ValueError, "Unknown benchmark option: " & argument)
  if result.samples < 1:
    raise newException(ValueError, "--samples must be at least 1")

proc main() =
  let options = parseOptions()
  let hasher = newArgon2idPasswordHasher(options.memoryKiB, options.iterations,
    options.threadCount, options.derivedBytes)
  let password = "benchmark-only password; never persist this value"
  var hashMilliseconds = newSeq[int64](options.samples)
  var verifyMilliseconds = newSeq[int64](options.samples)

  for sample in 0 ..< options.samples:
    let hashStarted = getMonoTime()
    let encoded = hasher.hashPassword(password)
    hashMilliseconds[sample] = (getMonoTime() - hashStarted).inMilliseconds
    if not hasher.verifyPassword(password, encoded):
      raise newException(Defect, "Argon2 benchmark hash did not verify")

    let verifyStarted = getMonoTime()
    if not hasher.verifyPassword(password, encoded):
      raise newException(Defect, "Argon2 benchmark verification failed")
    verifyMilliseconds[sample] = (getMonoTime() - verifyStarted).inMilliseconds

  var totalHash = 0'i64
  var totalVerify = 0'i64
  for elapsed in hashMilliseconds:
    totalHash += elapsed
  for elapsed in verifyMilliseconds:
    totalVerify += elapsed
  echo "algorithm=argon2id memory_kib=" & $options.memoryKiB &
    " iterations=" & $options.iterations & " threads=" & $options.threadCount &
    " derived_bytes=" & $options.derivedBytes & " samples=" & $options.samples &
    " hash_avg_ms=" & $(totalHash div options.samples.int64) &
    " verify_avg_ms=" & $(totalVerify div options.samples.int64)

when isMainModule:
  main()

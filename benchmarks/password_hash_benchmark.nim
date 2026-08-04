## Password hashing benchmark.
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
    algorithm: string
    memoryKiB: uint32
    iterations: uint32
    threadCount: uint32
    derivedBytes: uint32
    workFactor: int8
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
  result.algorithm = "argon2id"
  result.memoryKiB = 64 * 1024
  result.iterations = 3
  result.threadCount = 1
  result.derivedBytes = 32
  result.workFactor = 12
  result.samples = 5
  for argument in commandLineParams():
    if argument.startsWith("--algorithm="):
      result.algorithm = argument[12 .. ^1].toLowerAscii()
      if result.algorithm notin ["argon2id", "bcrypt"]:
        raise newException(ValueError,
          "Invalid --algorithm value: " & result.algorithm)
    elif argument.startsWith("--memory-kib="):
      result.memoryKiB = parseUintOption(argument, "--memory-kib", result.memoryKiB)
    elif argument.startsWith("--iterations="):
      result.iterations = parseUintOption(argument, "--iterations", result.iterations)
    elif argument.startsWith("--threads="):
      result.threadCount = parseUintOption(argument, "--threads", result.threadCount)
    elif argument.startsWith("--derived-bytes="):
      result.derivedBytes = parseUintOption(argument, "--derived-bytes", result.derivedBytes)
    elif argument.startsWith("--work-factor="):
      let raw = argument[14 .. ^1]
      try:
        result.workFactor = parseInt(raw).int8
      except ValueError:
        raise newException(ValueError, "Invalid --work-factor value: " & raw)
    elif argument.startsWith("--samples="):
      let raw = argument[10 .. ^1]
      try:
        result.samples = parseInt(raw)
      except ValueError:
        raise newException(ValueError, "Invalid --samples value: " & raw)
    elif argument in ["--help", "-h"]:
      echo "Usage: password_hash_benchmark [--algorithm=argon2id|bcrypt] " &
        "[--memory-kib=N] [--iterations=N] [--threads=N] " &
        "[--derived-bytes=N] [--work-factor=N] [--samples=N]"
      quit(0)
    else:
      raise newException(ValueError, "Unknown benchmark option: " & argument)
  if result.samples < 1:
    raise newException(ValueError, "--samples must be at least 1")

proc newBenchmarkHasher(options: BenchmarkOptions): PasswordHasher =
  ## Keep algorithm selection in the benchmark executable. Application code
  ## receives an already selected PasswordHasher through dependency injection.
  if options.algorithm == "bcrypt":
    return newBcryptPasswordHasher(options.workFactor)
  newArgon2idPasswordHasher(options.memoryKiB, options.iterations,
    options.threadCount, options.derivedBytes)

proc main() =
  let options = parseOptions()
  let hasher = newBenchmarkHasher(options)
  let password = "benchmark-only password; never persist this value"
  var hashMilliseconds = newSeq[int64](options.samples)
  var verifyMilliseconds = newSeq[int64](options.samples)

  for sample in 0 ..< options.samples:
    let hashStarted = getMonoTime()
    let encoded = hasher.hashPassword(password)
    hashMilliseconds[sample] = (getMonoTime() - hashStarted).inMilliseconds
    if not hasher.verifyPassword(password, encoded):
      raise newException(Defect, options.algorithm &
        " benchmark hash did not verify")

    let verifyStarted = getMonoTime()
    if not hasher.verifyPassword(password, encoded):
      raise newException(Defect, options.algorithm &
        " benchmark verification failed")
    verifyMilliseconds[sample] = (getMonoTime() - verifyStarted).inMilliseconds

  var totalHash = 0'i64
  var totalVerify = 0'i64
  for elapsed in hashMilliseconds:
    totalHash += elapsed
  for elapsed in verifyMilliseconds:
    totalVerify += elapsed
  var details = "algorithm=" & options.algorithm & " samples=" & $options.samples
  if options.algorithm == "bcrypt":
    details.add(" work_factor=" & $options.workFactor)
  else:
    details.add(" memory_kib=" & $options.memoryKiB &
      " iterations=" & $options.iterations &
      " threads=" & $options.threadCount &
      " derived_bytes=" & $options.derivedBytes)
  echo details & " hash_avg_ms=" & $(totalHash div options.samples.int64) &
    " verify_avg_ms=" & $(totalVerify div options.samples.int64)

when isMainModule:
  main()

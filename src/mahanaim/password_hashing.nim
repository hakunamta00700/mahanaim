## Password hashing boundary.
##
## Passwords never cross the framework as reusable plaintext credentials. The
## default adapter uses the standards-based PBKDF2-HMAC-SHA256 implementation
## supplied by nimcrypto; applications may replace it with Argon2id/bcrypt at
## this same API boundary without changing user or auth services.

import std/[strutils, sysrand]
import nimcrypto/[pbkdf2, sha2]

type
  Pbkdf2PasswordHasher* = ref object
    iterations*: int
    saltBytes*: int
    derivedBytes*: int

const
  defaultPasswordIterations* = 120000
  passwordHashAlgorithm = "pbkdf2-sha256"

proc hexEncode(value: openArray[byte]): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(value.len * 2)
  for item in value:
    result.add(digits[int(item shr 4)])
    result.add(digits[int(item and 0x0f)])

proc hexDecode(value: string): seq[byte] =
  ## Reject malformed encodings instead of silently truncating a hash.
  if value.len == 0 or value.len mod 2 != 0:
    return @[]
  result = newSeq[byte](value.len div 2)
  for index in 0 ..< result.len:
    let pair = value[index * 2 .. index * 2 + 1]
    try:
      result[index] = byte(parseHexInt(pair))
    except ValueError:
      return @[]

proc newPbkdf2PasswordHasher*(iterations = defaultPasswordIterations,
                              saltBytes = 16,
                              derivedBytes = 32): Pbkdf2PasswordHasher =
  ## Bounds prevent weak configurations and accidental resource-exhaustion
  ## values from becoming part of a deployed password verification path.
  if iterations < 10000 or iterations > 2000000:
    raise newException(ValueError, "PBKDF2 iterations must be 10000..2000000")
  if saltBytes < 16 or saltBytes > 64 or derivedBytes < 16 or derivedBytes > 64:
    raise newException(ValueError, "Invalid PBKDF2 salt or derived key size")
  Pbkdf2PasswordHasher(iterations: iterations, saltBytes: saltBytes,
    derivedBytes: derivedBytes)

proc derive(hasher: Pbkdf2PasswordHasher, password: string,
            salt: openArray[byte], iterations, outputBytes: int): seq[byte] =
  ## Keep KDF invocation in one private routine so hash and verify cannot drift.
  result = newSeq[byte](outputBytes)
  var context: HMAC[sha256]
  let written = pbkdf2(context, password, salt, iterations, result)
  if written != outputBytes:
    raise newException(ValueError, "PBKDF2 failed to derive the requested key")

proc hashPassword*(hasher: Pbkdf2PasswordHasher, password: string): string =
  ## Store algorithm parameters beside the digest so future work factors can
  ## be increased without invalidating existing accounts or guessing defaults.
  if hasher.isNil or password.len == 0:
    raise newException(ValueError, "Password hasher and password are required")
  let salt = urandom(hasher.saltBytes)
  let digest = hasher.derive(password, salt, hasher.iterations,
    hasher.derivedBytes)
  passwordHashAlgorithm & "$" & $hasher.iterations & "$" & hexEncode(salt) &
    "$" & hexEncode(digest)

proc constantTimeEquals(left, right: openArray[byte]): bool =
  var difference = left.len xor right.len
  let common = min(left.len, right.len)
  for index in 0 ..< common:
    difference = difference or (int(left[index]) xor int(right[index]))
  difference == 0

proc verifyPassword*(hasher: Pbkdf2PasswordHasher, password, encoded: string): bool =
  ## Invalid hashes fail closed and never escape as parsing exceptions to login
  ## routes, which keeps malformed database data from becoming an oracle.
  if hasher.isNil or password.len == 0:
    return false
  let parts = encoded.split('$')
  if parts.len != 4 or parts[0] != passwordHashAlgorithm:
    return false
  let iterations = try: parseInt(parts[1]) except ValueError: return false
  if iterations < 10000 or iterations > 2000000:
    return false
  let salt = hexDecode(parts[2])
  let expected = hexDecode(parts[3])
  if salt.len < 16 or expected.len == 0:
    return false
  let actual = hasher.derive(password, salt, iterations, expected.len)
  constantTimeEquals(actual, expected)

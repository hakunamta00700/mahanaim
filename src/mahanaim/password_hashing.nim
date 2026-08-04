## Password hashing boundary.
##
## Passwords never cross the framework as reusable plaintext credentials. The
## default adapter uses the standards-based PBKDF2-HMAC-SHA256 implementation
## supplied by nimcrypto; applications may replace it with Argon2id/bcrypt at
## this same API boundary without changing user or auth services.

import std/[options, strutils, sysrand, times]
import nimcrypto/[pbkdf2, sha2]
import ./security

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

proc passwordNeedsRehash*(hasher: Pbkdf2PasswordHasher,
                          encoded: string): bool =
  ## Password verification remains backward-compatible while callers can
  ## upgrade weak work factors after a successful login.
  if hasher.isNil:
    return true
  let parts = encoded.split('$')
  if parts.len != 4 or parts[0] != passwordHashAlgorithm:
    return true
  let iterations = try: parseInt(parts[1]) except ValueError: return true
  let salt = hexDecode(parts[2])
  let digest = hexDecode(parts[3])
  iterations < hasher.iterations or salt.len != hasher.saltBytes or
    digest.len != hasher.derivedBytes

proc issuePasswordResetTokenAt*(secret, subject: string, ttlSeconds,
                                issuedAt: int64): string =
  ## A reset token is an HMAC-signed envelope, not a password or session. The
  ## random nonce prevents identical tokens for the same subject and timestamp.
  ## One-time consumption still requires an application-owned used-token store.
  if secret.len < 32 or subject.strip().len == 0 or subject.contains('|'):
    raise newException(ValueError,
      "Reset token secret and subject are required")
  if ttlSeconds <= 0:
    raise newException(ValueError, "Reset token TTL must be positive")
  let expiresAt = issuedAt + ttlSeconds
  let nonce = hexEncode(urandom(16))
  signValue(secret, "password-reset|" & subject & "|" & $issuedAt & "|" &
    $expiresAt & "|" & nonce)

proc issuePasswordResetToken*(secret, subject: string,
                              ttlSeconds: int64): string =
  ## Production convenience wrapper uses the current Unix timestamp.
  issuePasswordResetTokenAt(secret, subject, ttlSeconds, getTime().toUnix)

proc verifyPasswordResetTokenAt*(secret, token, expectedSubject: string,
                                 now: int64): bool =
  ## Verification fails closed for malformed, mis-signed, wrong-subject, or
  ## expired tokens. Callers must atomically mark a successful token as used.
  if secret.len < 32 or expectedSubject.strip().len == 0:
    return false
  let signedPayload = verifySignedValue(secret, token)
  if signedPayload.isNone:
    return false
  let parts = signedPayload.get().split('|')
  if parts.len != 5 or parts[0] != "password-reset" or
     parts[1] != expectedSubject:
    return false
  let issuedAt = try: parseInt(parts[2]).int64 except ValueError: return false
  let expiresAt = try: parseInt(parts[3]).int64 except ValueError: return false
  issuedAt <= now and expiresAt > now and expiresAt > issuedAt and
    parts[4].len == 32

proc verifyPasswordResetToken*(secret, token, expectedSubject: string): bool =
  ## Production convenience wrapper uses the current Unix timestamp.
  verifyPasswordResetTokenAt(secret, token, expectedSubject, getTime().toUnix)

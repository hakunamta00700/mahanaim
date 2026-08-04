## Password hashing boundary.
##
## Passwords never cross the framework as reusable plaintext credentials. The
## default adapter uses the standards-based PBKDF2-HMAC-SHA256 implementation
## supplied by nimcrypto; applications may replace it with Argon2id/bcrypt at
## this same API boundary without changing user or auth services.

import std/[base64, locks, options, strutils, sysrand, tables, times]
import nimcrypto/[pbkdf2, sha2]
import argon2
import checksums/bcrypt as bcryptLib
import ./security

type
  PasswordHasher* = ref object of RootObj
    ## Algorithm-neutral boundary. Argon2id/bcrypt adapters implement these
    ## methods without changing account stores or authentication routes.

  Pbkdf2PasswordHasher* = ref object of PasswordHasher
    iterations*: int
    saltBytes*: int
    derivedBytes*: int

  Argon2idPasswordHasher* = ref object of PasswordHasher
    ## The encoded PHC string stores the algorithm parameters with each
    ## password. Keeping the policy here lets verifyAndRehash rotate costs
    ## without coupling account storage to the Argon2 implementation.
    memoryKiB*: uint32
    iterations*: uint32
    threadCount*: uint32
    derivedBytes*: uint32

  BcryptPasswordHasher* = ref object of PasswordHasher
    ## Bcrypt stores its version and cost inside the 60-character encoded
    ## value. The adapter keeps only the target cost; verification reads the
    ## persisted cost so existing accounts remain verifiable during rotation.
    workFactor*: int8

  PasswordVerification* = object
    ## Authentication code persists `encoded` only when `valid` is true;
    ## `rehashed` makes gradual work-factor rotation observable.
    valid*: bool
    rehashed*: bool
    encoded*: string

  PasswordChangeResult* = object
    ## The account service persists `encoded` only after `valid` is true.
    valid*: bool
    encoded*: string

  PasswordResetTokenStore* = ref object of RootObj
    ## Token consumption is an adapter boundary because production systems
    ## should atomically persist this state in their existing user/session DB.

  InMemoryPasswordResetTokenStore* = ref object of PasswordResetTokenStore
    ## The reference adapter is process-local and bounded for tests/dev only.
    usedTokens: Table[string, int64]
    maxEntries*: int
    lock: Lock

const
  defaultPasswordIterations* = 120000
  passwordHashAlgorithm = "pbkdf2-sha256"
  minBcryptWorkFactor* = 4
  maxBcryptWorkFactor* = 31

method hashPassword*(hasher: PasswordHasher, password: string): string
    {.base, gcsafe.} =
  discard hasher
  discard password
  raise newException(ValueError, "Password hasher does not implement hashing")

method verifyPassword*(hasher: PasswordHasher, password, encoded: string): bool
    {.base, gcsafe.} =
  discard hasher
  discard password
  discard encoded
  false

method passwordNeedsRehash*(hasher: PasswordHasher, encoded: string): bool
    {.base, gcsafe.} =
  discard hasher
  discard encoded
  true

method verifyAndRehash*(hasher: PasswordHasher,
                        password, encoded: string): PasswordVerification
    {.base, gcsafe.} =
  result.valid = hasher.verifyPassword(password, encoded)
  if not result.valid:
    return
  if hasher.passwordNeedsRehash(encoded):
    result.encoded = hasher.hashPassword(password)
    result.rehashed = true
  else:
    result.encoded = encoded

method changePassword*(hasher: PasswordHasher,
                       currentPassword, newPassword, encoded: string):
    PasswordChangeResult {.base, gcsafe.} =
  if currentPassword.len == 0 or newPassword.len == 0 or
      currentPassword == newPassword or
      not hasher.verifyPassword(currentPassword, encoded):
    return PasswordChangeResult(valid: false, encoded: "")
  PasswordChangeResult(valid: true, encoded: hasher.hashPassword(newPassword))

method consumeToken*(store: PasswordResetTokenStore, token: string,
                     expiresAt, now: int64): bool {.base, gcsafe.} =
  ## A backend must make check-and-record one atomic operation.
  discard store
  discard token
  discard expiresAt
  discard now
  raise newException(ValueError, "Password reset token store is not implemented")

proc newInMemoryPasswordResetTokenStore*(maxEntries = 10000):
    InMemoryPasswordResetTokenStore =
  ## Bound memory growth even if a deployment repeatedly issues reset tokens.
  if maxEntries < 1:
    raise newException(ValueError, "Password reset token store capacity is required")
  new(result)
  result.usedTokens = initTable[string, int64]()
  result.maxEntries = maxEntries
  initLock(result.lock)

method consumeToken*(store: InMemoryPasswordResetTokenStore, token: string,
                     expiresAt, now: int64): bool {.gcsafe.} =
  ## The lock covers expiry cleanup and insertion so concurrent requests cannot
  ## redeem the same signed token twice through this reference adapter.
  if token.len == 0 or expiresAt <= now:
    return false
  acquire(store.lock)
  defer: release(store.lock)
  var expired: seq[string] = @[]
  for existing, expiry in store.usedTokens:
    if expiry <= now:
      expired.add(existing)
  for existing in expired:
    store.usedTokens.del(existing)
  if store.usedTokens.hasKey(token):
    return false
  if store.usedTokens.len >= store.maxEntries:
    return false
  store.usedTokens[token] = expiresAt
  true

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

proc newArgon2idPasswordHasher*(memoryKiB: uint32 = 64 * 1024,
                                iterations: uint32 = 3,
                                threadCount: uint32 = 1,
                                derivedBytes: uint32 = 32):
    Argon2idPasswordHasher =
  ## Bounds reject both accidentally weak settings and unbounded request-cost
  ## settings. Applications may tune within these limits using deployment
  ## benchmarks, while the encoded hash remains self-describing.
  if memoryKiB < 8 * 1024 or memoryKiB > 1024 * 1024:
    raise newException(ValueError, "Argon2 memory must be 8192..1048576 KiB")
  if iterations < 1 or iterations > 10:
    raise newException(ValueError, "Argon2 iterations must be 1..10")
  if threadCount < 1 or threadCount > 32:
    raise newException(ValueError, "Argon2 threads must be 1..32")
  if derivedBytes < 16 or derivedBytes > 64:
    raise newException(ValueError, "Argon2 output size must be 16..64 bytes")
  Argon2idPasswordHasher(memoryKiB: memoryKiB, iterations: iterations,
    threadCount: threadCount, derivedBytes: derivedBytes)

proc newBcryptPasswordHasher*(workFactor: int8 = 12): BcryptPasswordHasher =
  ## Bcrypt cost selection is deliberately bounded by the algorithm's encoded
  ## format. Deployments should select the value with `passwordBenchmark` on
  ## their real login hosts instead of treating the default as a guarantee.
  if workFactor < minBcryptWorkFactor or workFactor > maxBcryptWorkFactor:
    raise newException(ValueError, "Bcrypt work factor must be 4..31")
  BcryptPasswordHasher(workFactor: workFactor)

type ParsedBcryptHash = object
  ## Only fields needed for verification and gradual cost rotation are kept;
  ## the native implementation receives the complete encoded value later.
  workFactor: int8

proc parseBcryptHash(encoded: string): Option[ParsedBcryptHash] =
  ## Delegate alphabet/version parsing to Nim's maintained bcrypt
  ## implementation, then require the complete 60-character persisted form.
  if encoded.len != 60 or encoded[0] != '$' or encoded[1] != '2' or
      encoded[2] notin ['a', 'b', 'y'] or encoded[3] != '$' or
      encoded[6] != '$' or encoded[4] < '0' or encoded[4] > '9' or
      encoded[5] < '0' or encoded[5] > '9':
    return none(ParsedBcryptHash)
  try:
    let parsed = bcryptLib.parseSalt(encoded)
    some(ParsedBcryptHash(workFactor: int8(parsed.costFactor)))
  except ValueError:
    none(ParsedBcryptHash)

proc constantTimeTextEquals(left, right: string): bool {.gcsafe.}

method hashPassword*(hasher: BcryptPasswordHasher, password: string): string
    {.gcsafe.} =
  if hasher.isNil or password.len == 0:
    raise newException(ValueError, "Password hasher and password are required")
  let salt = bcryptLib.generateSalt(bcryptLib.CostFactor(hasher.workFactor))
  let encoded = $(bcryptLib.bcrypt(password, salt))
  if parseBcryptHash(encoded).isNone:
    raise newException(ValueError, "Bcrypt returned an invalid encoded hash")
  encoded

method verifyPassword*(hasher: BcryptPasswordHasher,
                       password, encoded: string): bool {.gcsafe.} =
  if hasher.isNil or password.len == 0:
    return false
  if parseBcryptHash(encoded).isNone:
    return false
  try:
    ## Passing the persisted hash as the salt makes the maintained implementation
    ## recompute the same cost/salt. The final comparison stays in this module
    ## so every built-in adapter shares the same constant-time text policy.
    let regenerated = $(bcryptLib.bcrypt(password,
      bcryptLib.parseSalt(encoded)))
    constantTimeTextEquals(regenerated, encoded)
  except CatchableError:
    false

method passwordNeedsRehash*(hasher: BcryptPasswordHasher,
                            encoded: string): bool {.gcsafe.} =
  if hasher.isNil:
    return true
  let parsed = parseBcryptHash(encoded)
  parsed.isNone or parsed.get().workFactor != hasher.workFactor

type ParsedArgon2Hash = object
  ## Only the PHC fields required by this adapter are retained. A malformed or
  ## non-Argon2id string is represented by `none` and never reaches the C API.
  memoryKiB: uint32
  iterations: uint32
  threadCount: uint32
  derivedBytes: uint32
  salt: string

proc parseArgon2idHash(encoded: string): Option[ParsedArgon2Hash] =
  ## Parse the standard `$argon2id$v=19$m=...,t=...,p=...$salt$digest` form.
  ## The parser is deliberately strict because this value is persisted input.
  try:
    let parts = encoded.split('$')
    if parts.len != 6 or parts[1] != "argon2id" or parts[2] != "v=19":
      return none(ParsedArgon2Hash)
    var memory = 0
    var iterations = 0
    var threads = 0
    for item in parts[3].split(','):
      let pair = item.split('=', maxsplit = 1)
      if pair.len != 2:
        return none(ParsedArgon2Hash)
      let value = parseInt(pair[1])
      if value < 1:
        return none(ParsedArgon2Hash)
      case pair[0]
      of "m": memory = value
      of "t": iterations = value
      of "p": threads = value
      else: return none(ParsedArgon2Hash)
    let salt = decode(parts[4])
    let digest = decode(parts[5])
    if memory > int(high(uint32)) or iterations > int(high(uint32)) or
       threads > int(high(uint32)) or digest.len == 0:
      return none(ParsedArgon2Hash)
    some(ParsedArgon2Hash(memoryKiB: uint32(memory),
      iterations: uint32(iterations), threadCount: uint32(threads),
      derivedBytes: uint32(digest.len), salt: salt))
  except CatchableError:
    none(ParsedArgon2Hash)

proc constantTimeTextEquals(left, right: string): bool {.gcsafe.} =
  ## Hash strings are compared without an early-exit prefix leak. The length is
  ## folded into the accumulator as well, matching the byte-level policy used
  ## by the PBKDF2 adapter.
  var difference = left.len xor right.len
  let common = min(left.len, right.len)
  for index in 0 ..< common:
    difference = difference or (ord(left[index]) xor ord(right[index]))
  difference == 0

method hashPassword*(hasher: Argon2idPasswordHasher, password: string): string
    {.gcsafe.} =
  if hasher.isNil or password.len == 0:
    raise newException(ValueError, "Password hasher and password are required")
  ## The C-backed dependency receives a random salt and emits the standard
  ## `$argon2id$...` PHC representation; plaintext never persists.
  let salt = cast[string](urandom(16))
  argon2("id", password, salt, hasher.iterations, hasher.memoryKiB,
    hasher.threadCount, hasher.derivedBytes).enc

method verifyPassword*(hasher: Argon2idPasswordHasher,
                       password, encoded: string): bool {.gcsafe.} =
  if hasher.isNil or password.len == 0 or encoded.len == 0:
    return false
  try:
    let parsed = parseArgon2idHash(encoded)
    if parsed.isNone:
      return false
    let value = parsed.get()
    let regenerated = argon2("id", password, value.salt, value.iterations,
      value.memoryKiB, value.threadCount, value.derivedBytes).enc
    constantTimeTextEquals(regenerated, encoded)
  except CatchableError:
    false

method passwordNeedsRehash*(hasher: Argon2idPasswordHasher,
                            encoded: string): bool {.gcsafe.} =
  if hasher.isNil:
    return true
  let parsed = parseArgon2idHash(encoded)
  if parsed.isNone:
    return true
  let value = parsed.get()
  value.memoryKiB != hasher.memoryKiB or
    value.iterations != hasher.iterations or
    value.threadCount != hasher.threadCount or
    value.derivedBytes != hasher.derivedBytes

proc derive(hasher: Pbkdf2PasswordHasher, password: string,
            salt: openArray[byte], iterations, outputBytes: int): seq[byte] =
  ## Keep KDF invocation in one private routine so hash and verify cannot drift.
  result = newSeq[byte](outputBytes)
  var context: HMAC[sha256]
  let written = pbkdf2(context, password, salt, iterations, result)
  if written != outputBytes:
    raise newException(ValueError, "PBKDF2 failed to derive the requested key")

method hashPassword*(hasher: Pbkdf2PasswordHasher, password: string): string
    {.gcsafe.} =
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

method verifyPassword*(hasher: Pbkdf2PasswordHasher, password, encoded: string): bool
    {.gcsafe.} =
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

method passwordNeedsRehash*(hasher: Pbkdf2PasswordHasher,
                            encoded: string): bool {.gcsafe.} =
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

method verifyAndRehash*(hasher: Pbkdf2PasswordHasher,
                        password, encoded: string): PasswordVerification
    {.gcsafe.} =
  ## Combine verify-then-upgrade so failed attempts never replace stored hashes.
  result.valid = hasher.verifyPassword(password, encoded)
  if not result.valid:
    return
  if hasher.passwordNeedsRehash(encoded):
    result.encoded = hasher.hashPassword(password)
    result.rehashed = true
  else:
    result.encoded = encoded

method changePassword*(hasher: Pbkdf2PasswordHasher,
                       currentPassword, newPassword, encoded: string):
    PasswordChangeResult {.gcsafe.} =
  ## Keep current-password verification and new-hash issuance together. The
  ## framework never persists accounts here; persistence remains the caller's
  ## transaction responsibility, preserving this module's single purpose.
  if currentPassword.len == 0 or newPassword.len == 0 or
      currentPassword == newPassword or
      not hasher.verifyPassword(currentPassword, encoded):
    return PasswordChangeResult(valid: false, encoded: "")
  PasswordChangeResult(valid: true, encoded: hasher.hashPassword(newPassword))

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

proc resetTokenExpiryAt(secret, token: string): Option[int64] =
  ## Extract only the expiry needed by the consumption store after signature
  ## verification; malformed payloads remain indistinguishable from invalid.
  let signedPayload = verifySignedValue(secret, token)
  if signedPayload.isNone:
    return none(int64)
  let parts = signedPayload.get().split('|')
  if parts.len != 5 or parts[0] != "password-reset":
    return none(int64)
  try:
    some(parseInt(parts[3]).int64)
  except ValueError:
    none(int64)

proc consumePasswordResetTokenAt*(store: PasswordResetTokenStore,
                                  secret, token, expectedSubject: string,
                                  now: int64): bool =
  ## Verify first, then atomically consume. A successful return is the only
  ## point at which a password-reset handler may mutate the account password.
  if store.isNil or not verifyPasswordResetTokenAt(secret, token,
      expectedSubject, now):
    return false
  let expiry = resetTokenExpiryAt(secret, token)
  if expiry.isNone:
    return false
  store.consumeToken(token, expiry.get(), now)

proc consumePasswordResetToken*(store: PasswordResetTokenStore,
                                secret, token, expectedSubject: string): bool =
  ## Production convenience wrapper uses the current Unix timestamp.
  consumePasswordResetTokenAt(store, secret, token, expectedSubject,
    getTime().toUnix)

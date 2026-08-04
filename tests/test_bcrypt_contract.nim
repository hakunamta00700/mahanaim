## Bcrypt adapter contract.
##
## This fixture is intentionally separate from the default unit suite because
## bcrypt is an optional native dependency. It proves that the framework's
## algorithm-neutral PasswordHasher boundary can host a real bcrypt adapter
## without leaking the package's salt or C API into account services.

import std/[strutils, unittest]
import mahanaim/password_hashing

suite "bcrypt password hasher contract":
  test "hashes, verifies, rejects tampering, and rotates work factor":
    let hasher = newBcryptPasswordHasher(workFactor = 4)
    let encoded = hasher.hashPassword("correct horse battery staple")

    check encoded.len >= 59
    check encoded.startsWith("$2")
    check hasher.verifyPassword("correct horse battery staple", encoded)
    check not hasher.verifyPassword("wrong password", encoded)
    check not hasher.passwordNeedsRehash(encoded)

    let stronger = newBcryptPasswordHasher(workFactor = 5)
    check stronger.passwordNeedsRehash(encoded)
    let upgraded = stronger.verifyAndRehash(
      "correct horse battery staple", encoded)
    check upgraded.valid
    check upgraded.rehashed
    check stronger.verifyPassword("correct horse battery staple", upgraded.encoded)

    let changed = stronger.changePassword(
      "correct horse battery staple", "new secure password", upgraded.encoded)
    check changed.valid
    check stronger.verifyPassword("new secure password", changed.encoded)

    check not hasher.verifyPassword(
      "correct horse battery staple", encoded[0 .. ^2] &
        (if encoded[^1] == '0': "1" else: "0"))

  test "verifies a standard external bcrypt vector":
    ## This vector comes from the maintained checksums implementation's public
    ## contract and prevents the adapter from only interoperating with hashes
    ## it generated itself.
    let knownGood =
      "$2b$06$LzUyyYdKBoEy9V4NTvxDH.O11KQP30/Zyp5pQAQ.0Cy89WnkD5Jjy"
    let hasher = newBcryptPasswordHasher(workFactor = 6)
    check hasher.verifyPassword("correct horse battery staple", knownGood)
    check not hasher.verifyPassword("incorrect horse battery staple", knownGood)
    check not hasher.passwordNeedsRehash(knownGood)

  test "rejects unsafe work factors and empty passwords":
    expect ValueError:
      discard newBcryptPasswordHasher(workFactor = 3)
    expect ValueError:
      discard newBcryptPasswordHasher(workFactor = 32)

    let hasher = newBcryptPasswordHasher(workFactor = 4)
    expect ValueError:
      discard hasher.hashPassword("")
    check not hasher.verifyPassword("secret", "x".repeat(60))

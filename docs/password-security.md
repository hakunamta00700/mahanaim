# Password security

**Audience:** maintainers choosing password hashing parameters.
**Verified with:** `nimble passwordBenchmark`, `nimble test`

Prefer Argon2id where its memory cost fits the production login workload.
`newArgon2idPasswordHasher` keeps memory, iterations, threads, and output length
explicit. bcrypt is available through `newBcryptPasswordHasher` for compatible
deployments; PBKDF2 is a compatibility/reference option rather than a preferred
new-password default.

Store only the encoded verifier. `verifyAndRehash` lets a successful login rotate
an outdated cost or algorithm without a separate reset flow. Benchmark on the
actual deployment hardware with realistic concurrent login load, then choose a
cost that resists guessing without exhausting memory or latency budget.

Apply login throttling/rate limiting to identifiers and trusted client signals,
use generic invalid-credential responses, and record only redacted audit events.
Never add a password, hash, reset token, or benchmark sample containing real
credentials to source control or application logs.

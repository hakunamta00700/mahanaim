# Release guide

**Audience:** maintainers qualifying a framework or application release.
**Verified with:** `nimble verify`, release CI, and artifact manifest validation.

Update version/changelog and verify public support claims in the
[support matrix](support-matrix.md). Review `nimble.lock` and run:

```text
nimble check
nimble test
nimble verify
nimble planStatus
```

Create artifacts on each supported target, calculate SHA-256 from actual bytes,
write the deterministic artifact manifest, and validate it before upload. A CI
matrix is evidence only when platform jobs and artifacts succeeded; local results
do not replace required macOS/Linux/provider live evidence.

Publish compatibility/deprecation notes for public API changes, attach the exact
OpenAPI artifact when needed, and retain rollback inputs. On a failed command,
stop qualification, fix or revert, and rerun the affected gate.

# Static assets

**Audience:** deployers collecting CSS, JavaScript, and images.
**Verified with:** `mahanaim static collect`, `nimble test`

Run `mahanaim static collect` with an application-owned source and output policy.
The collector rejects unsafe source/output relationships and path traversal, then
copies a deterministic asset set. Do not use upload storage as the static output
directory, and do not expose writable upload paths through the static server.

Serve collected output through a reverse proxy or CDN in production. The framework
does not turn a collection result into a complete CDN cache policy: configure
immutable fingerprinted assets, cache headers, invalidation, compression, and TLS
at the serving layer. Verify that the public proxy cannot resolve paths outside
the collected output root.

Keep static artifact collection in CI/release steps and deploy the exact generated
directory or manifest with the application revision. Use a staging smoke test for
cache headers, Range/ETag behavior, and CDN invalidation.

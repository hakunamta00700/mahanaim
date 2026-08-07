# Email and notifications

**Audience:** applications delivering email, flash messages, feeds, and discovery metadata.
**Status:** SMTP delivery is experimental. **Verified with:** `nimble test`

`EmailMessage` is delivered through callback, SMTP, or bounded retry transports.
The application owns recipient validation, template rendering, idempotency, and
provider credentials. Require authenticated TLS for SMTP and test a disposable
wire endpoint before production; the callback transport is a local/test boundary.

Flash messages are request/session scoped and consumed once. Sitemap and RSS/Atom
helpers render escaped XML and reject unsafe URLs. They are output helpers, not
an authorization mechanism: only publish public URLs and do not include private
identifiers or secrets in feed data.

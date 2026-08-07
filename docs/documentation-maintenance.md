# Documentation maintenance

**Owners:** feature author for the changed behavior; release reviewer for final consistency.
**Review points:** before release, every public API/CLI change, and every experimental promotion.

Every feature change updates its user guide, the [documentation index](index.md),
support matrix maturity/evidence, and executable example/verification where
applicable. Update `CHANGELOG.md` with the user-visible change and link new
guides, migration cautions, or deprecation replacements.

Before merge, run `nimble docsCheck`, `nimble docsExamples`, and
`nimble publicApiCheck`; run required live gates or state their credentialed
environment evidence explicitly. Before release, reconcile support matrix,
changelog, API reference, guides, examples, and deployment limitations.

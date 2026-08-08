# Public API reference

This reference is maintained from public `*` exports in `src/mahanaim` and the
compile contract in `tests/test_public_api_compile.nim`. `nimble publicApiCheck`
is the compatibility gate; `nimble docsExamples` verifies the minimal public
application example.

| Area | Reference | Source boundary |
| --- | --- | --- |
| application and HTTP | [core API](core.md) | `src/mahanaim/core.nim`, `application.nim`, `router.nim` |
| validation and response | [core API](core.md) | `validation.nim`, `response_policy.nim` |
| extension points | [extension guide](../extension-authoring.md) | public Application plugin/module APIs |
| every umbrella export | [public module map](public-modules.md) | `src/mahanaim.nim` |

New public exports require a brief, parameter/return contract, ownership and
lifecycle notes, error behavior, and a minimum example here or in its feature
guide. Deliberately excluded internal helpers must remain unexported; a public
export with no documented surface is a documentation defect.

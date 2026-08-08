# Templates

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** server-rendered application developers.
**Verified with:** `nimble test`

The built-in `TemplateEngine` uses explicit registration and mandatory HTML
escaping. Register source directly, a single file, or an application-owned
directory. Directory names are relative, slash-normalized, and extension-free:
`templates/layouts/base.html` is named `layouts/base`.

```nim
let engine = newTemplateEngine()
engine.loadTemplateDirectory("templates")
engine.registerTemplate("pages/home", "<h1>{{ title|upper }}</h1>")
let html = engine.render("pages/home", newTemplateContext([("title", "Welcome")]))
```

Supported syntax is `{{ value|filter }}`, `{% if key %}` / `else`,
`{% for item in items %}`, `{% include "partial" %}`, and `{% extends "base" %}`
with named blocks. Collections are explicit `TemplateRenderContext` data, not
strings inferred by the engine. Unknown names, missing collections, and excessive
inheritance depth fail explicitly.

Use `registerFilter`, `registerTag`, or `registerHelper` for scoped extensions.
Their output is still HTML escaped. Do not return user-controlled markup through
a helper or concatenate untrusted HTML into template source. Filters `upper`,
`lower`, and `trim` are built in. Request-local locale formatting uses
`setLocaleFormatter` and `format_decimal` / `format_datetime`, not global state.

Translations can be registered directly or loaded from JSON catalogs. Missing
translations fall back to the default locale, then the key; duplicates fail at
registration. For forms see [forms](forms.md). Admin uses the same language but
a separate context and lookup convention: [Admin templates](admin-template-customization.md).

## 문제 해결

| 증상 | 원인과 확인 방법 | 안전한 조치 |
| --- | --- | --- |
| 사용자 입력이 HTML로 보이거나 XSS가 우려됨 | helper/filter가 raw request 값을 markup으로 조합했는지 확인한다. 기본 engine은 `{{ value }}`를 escape한다. | 사용자 입력을 `TemplateRenderContext` 값으로 전달하고 기본 escape를 유지한다. 신뢰한 markup도 별도 allow-list 경계를 둔다. |
| `{% for item in items %}`가 실패함 | `items`가 문자열이거나 context에 없는 collection일 수 있다. engine은 collection을 자동 추론하지 않는다. | route에서 명시적인 collection을 context에 넣고, 비어 있는 경우도 빈 sequence로 전달한다. |
| template을 찾을 수 없음 | directory가 composition root에서 로드되지 않았거나 이름에 `.html` 확장자를 붙였을 수 있다. | `loadTemplateDirectory("templates")`를 startup 전에 호출하고 `pages/home`처럼 slash-normalized, extension 없는 이름을 사용한다. |
| form POST가 CSRF 오류로 거부됨 | hidden field만 렌더링하고 request-bound token 또는 검증 middleware를 누락했을 수 있다. | `renderForm(..., request, ...)` 또는 `csrfHiddenInput(request, policy)`를 사용하고 같은 policy의 CSRF middleware를 유지한다. |

관련 문서: [폼과 CSRF](forms.md), [서버 렌더링](server-rendered-pages.md),
[HTMX](htmx.md), [보안](security.md).

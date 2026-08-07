# Templates

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

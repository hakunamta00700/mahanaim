# Moving from Django

**Audience:** Django teams evaluating or moving a service to Mahanaim.

Mahanaim's `mahanaim new` is closest to `startproject`, and `mahanaim app` plus
`ApplicationModule` is closest to `startapp`. Unlike Django, neither apps,
models, Admin resources, plugins, nor commands are discovered automatically:
install/register them explicitly in the composition root.

| Django | Mahanaim |
| --- | --- |
| URLconf | `app.get/post/addRoute`, groups, route DSL |
| Model/Form/Serializer | metadata + `FieldSpec` + forms/serialization |
| `makemigrations`/`migrate` | registered migrations + `mahanaim db` commands |
| `ModelAdmin` | explicit `AdminRegistry` resource + authorization + audit |
| management command | application command registry / framework CLI |
| Django template | `TemplateEngine` / `TemplateAdapter` |

Start by moving one bounded route and schema, then add tests before replacing
templates/admin pages. Review [Admin](admin.md), [plugins](plugins.md),
[authentication](authentication.md), and [known limitations](known-limitations.md)
before assuming a Django integration is equivalent.

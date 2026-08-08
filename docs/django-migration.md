# Django에서 이관

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

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

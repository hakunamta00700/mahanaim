# 폼과 CSRF

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** developers rendering validated server-side forms.
**Verified with:** `nimble test`

`bindForm(request, schema)` uses the same `FieldSpec` validation as APIs and
returns `FormState` with values and per-field errors.

```nim
let schema = [stringField("email", flBody, maxLength = 254)]
let form = bindForm(request, schema)
if form.errors.len > 0:
  return htmlResponse(renderForm(form, request, action = "/signup"))
```

`renderForm` selects safe default widgets, escapes values and errors, and uses a
request-bound CSRF token when given `request`. Handwritten templates should use
`csrfHiddenInput(request, policy)` rather than minting another token. Rendering
the field does not replace CSRF validation middleware.

`bindModelForm` and `bindModelFormSet` derive schemas from `ModelMetadata`, so
forms, validation, and OpenAPI retain a single declaration. `bindFormSet` keeps
rows independent and gathers every error. A request-aware formset shares one
CSRF token across all rows.

Use `WidgetRegistry.registerWidget` to replace a field widget. The callback must
escape inserted values and must not trust raw request input. Keep business rules
in `FieldSpec` or model metadata, not the widget.

템플릿과 HTMX representation을 결합한 실제 route는
[`examples/template_form_htmx.nim`](../examples/template_form_htmx.nim)을 참고한다.
이 예제는 과도한 길이의 `email` form input이 escaped validation error로 렌더링되는지도
`nimble docsExamples`에서 검증한다.

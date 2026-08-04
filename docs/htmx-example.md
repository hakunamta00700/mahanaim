# HTML·JSON·HTMX 같은 route 예제

`htmlJsonResponse`는 route의 도메인 조회 결과를 한 번만 계산한 뒤, 요청의
`Accept`와 `HX-Request`에 따라 표현만 선택한다. HTML 요청은 전체 문서를,
HTMX 요청은 partial을, JSON 요청은 API 문서를 반환한다.

```nim
proc items(request: Request): Future[Response] {.async, gcsafe.} =
  let items = loadItems()
  let context = itemsTemplateContext(items)
  return htmlJsonResponse(request,
    engine.render("items-page", context),
    engine.render("items-list", context),
    $itemsJson(items))
```

템플릿의 전체 문서는 partial을 포함하는 형태로 유지한다.

```html
<!-- items-page -->
<main><ul id="items">{% include "items-list" %}</ul></main>

<!-- items-list -->
{% for item in items %}<!-- application code expands the list -->{% endfor %}
```

HTMX 요청에는 `HX-Request: true`를 사용하고, API client는
`Accept: application/json`을 사용한다. 응답에는 `Vary: Accept, HX-Request`가
포함되어 캐시가 서로 다른 표현을 섞지 않는다. 서버는 신뢰할 수 없는 값을
템플릿에 넣기 전에 기존 auto-escaping template engine을 사용해야 한다.

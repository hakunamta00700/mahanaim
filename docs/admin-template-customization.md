# Admin 템플릿 커스터마이징

일반 페이지 템플릿의 등록·escaping·include·inheritance·locale 규칙은 [템플릿 가이드](templates.md)를 따릅니다. Admin 템플릿은 같은 엔진을 사용하지만, 아래의 Admin 전용 컨텍스트와 `admin/...` override 탐색 규칙을 추가로 가집니다. 일반 `TemplateRenderContext`를 Admin 화면에 임의로 기대하지 마십시오.

Admin의 기본 HTML은 `src/mahanaim/admin_templates/`에 있는 파일로 작성되며,
컴파일 시 AdminRegistry에 포함됩니다. 따라서 프레임워크 패키지를 배포한 뒤에도
프로젝트는 자체 템플릿 디렉터리만으로 화면을 교체할 수 있습니다.

`AdminRegistry`를 만들고 라우트를 등록하기 전에 프로젝트 템플릿을 로드합니다.

```nim
let admin = newAdminRegistry()
admin.loadAdminTemplateDirectory("templates")
registerAdminRoutes(app, admin)
```

템플릿 디렉터리는 아래 이름을 사용합니다.

| 파일 | 적용 범위 |
| --- | --- |
| `templates/admin/base.html` | 모든 기본 화면의 공통 레이아웃 |
| `templates/admin/list.html` | 모든 리소스의 목록 화면 |
| `templates/admin/form.html` | 모든 리소스의 생성·유효성 오류 화면 |
| `templates/admin/detail.html` | 모든 리소스의 상세·수정 화면 |
| `templates/admin/<resource>/list.html` | 해당 리소스의 목록 화면 |
| `templates/admin/<resource>/form.html` | 해당 리소스의 생성·유효성 오류 화면 |
| `templates/admin/<resource>/detail.html` | 해당 리소스의 상세·수정 화면 |

리소스별 파일이 전역 파일보다 우선합니다. 예를 들어 `items` 리소스의 목록만
바꾸려면 다음 파일을 만들면 됩니다.

```html
<!-- templates/admin/items/list.html -->
<main class="inventory" data-resource="{{ resource_name }}">
  <h1>상품 목록</h1>
</main>
```

기본 템플릿 이름은 `adminTemplateNames()`로 확인할 수 있고, 파일 대신
`registerAdminTemplate("admin/items/detail", source)`로 등록할 수도 있습니다.
템플릿은 기존 TemplateEngine의 `extends`, `block`, `include`, `if`, `for` 문법과
자동 HTML escaping을 그대로 사용합니다.

기본 컨텍스트는 화면마다 다음 값을 제공합니다.

- 목록: `resource_name`, `new_url`, `columns`, `rows`, `row.cells`
- 생성 폼: `resource_name`, `action`, `csrf_enabled`, `csrf_field_name`,
  `csrf_token`, `fields`, `field.errors`
- 상세 화면: `resource_name`, `identifier`, `list_url`, `action`, `delete_url`,
  `detail_fields`, `form_fields`, `field.errors` 및 CSRF 값

`formLayout`은 이전 버전과 호환되는 우선 확장 지점입니다. 이를 설정한 리소스는
생성·수정 폼 조각을 `formLayout`이 렌더링합니다. 전체 화면을 템플릿으로 통일해
커스터마이즈하려면 해당 리소스에 `formLayout`을 설정하지 않고 위의 `form` 및
`detail` 템플릿을 사용하세요.

업그레이드 시에는 `adminTemplateNames()`의 기본 이름과 제공 컨텍스트를 기준으로 override를 검토하고, 전역 override와 리소스별 override를 모두 browser smoke test합니다. 리소스별 `list/form/detail`은 같은 전역 화면보다 우선하며, `formLayout`이 설정되면 해당 생성·수정 조각이 템플릿보다 우선합니다. 한 화면을 교체할 때는 이 우선순위를 섞지 말고 하나의 소유 지점을 선택하세요.

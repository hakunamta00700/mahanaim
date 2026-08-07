# Mahanaim 기능 매핑

**대상 독자:** Django 또는 Litestar에서 Mahanaim으로 이전하는 개발자
**안정성 기준:** 지원 여부는 [지원 매트릭스](support-matrix.md)가 기준이다.
**검증:** `nimble docsCheck`

이 표는 이름이 비슷한 기능을 찾기 위한 안내다. API 모양과 lifecycle은 다를 수
있으므로 실제 적용 전 연결된 가이드를 읽어야 한다.

| 필요 | Django | Litestar | Mahanaim | 상태·문서 |
| --- | --- | --- | --- | --- |
| 프로젝트 생성 | `startproject` | app factory | `mahanaim new NAME [PATH]` | [시작 가이드](getting-started.md) |
| 기능 모듈 생성 | `startapp` | module/package | `mahanaim app NAME [PROJECT_ROOT]`, `ApplicationModule` | [프로젝트 구조](project-layout.md) |
| URL 등록 | URLconf | route handler | `app.get/post/addRoute`, route DSL | [라우팅](routing.md) |
| 요청 검증 | Form/Serializer | DTO/signature | `FieldSpec`, schema, model metadata | [요청과 검증](requests-and-validation.md) |
| HTML 템플릿 | Django templates | template backend | `TemplateEngine`, `TemplateAdapter` | 템플릿 가이드 작성 예정 |
| 폼·CSRF | Form/FormSet | plugin/integration | `FormState`, model form/formset, security policy | 폼 가이드 작성 예정 |
| ORM/쿼리 | Model/QuerySet | SQLAlchemy integration | model metadata, `QuerySet`, `DatabaseRepository` | 모델/쿼리 가이드 작성 예정 |
| migration | `makemigrations`/`migrate` | Alembic integration | migration registry, `mahanaim db status|up|rollback|seed` | migration 가이드 작성 예정 |
| Admin | `ModelAdmin` | third-party | explicit `AdminRegistry`/resource/authorization/audit | Admin 가이드 작성 예정 — experimental |
| Admin UI 변경 | template override | custom UI | `templates/admin/...`, `formLayout` | [Admin 템플릿](admin-template-customization.md) |
| 관리 명령 | `manage.py` commands | CLI plugins | app-owned command registry, framework CLI | [CLI](cli-reference.md) |
| 인증 | auth backends | guards | session/bearer/JWT/auth backend contracts | 인증 가이드 작성 예정 |
| 권한 | permissions | guards | `AuthorizationPolicy` role/group/object rules | 권한 가이드 작성 예정 |
| API 문서 | DRF schema | built-in OpenAPI | OpenAPI registry, UI, TypeScript client | OpenAPI 가이드 작성 예정 — experimental |
| 백그라운드 작업 | Celery/RQ | task plugin | queue, retry, idempotency, durable job store | background job 가이드 작성 예정 — experimental |
| WebSocket/SSE | Channels/streaming | socket/SSE | WebSocket/SSE routes, channel layer | 실시간 가이드 작성 예정 — experimental |
| 플러그인 | Django app package | plugin | explicit manifest/phase/dependency plugin | 플러그인 가이드 작성 예정 |

## 중요한 차이

1. **자동 발견보다 명시적 설치:** ApplicationModule, plugin, Admin resource, command는
   composition root에서 등록한다. 모듈을 파일 시스템에서 자동 발견하지 않는다.
2. **모델은 metadata 경계:** Nim 타입·macro가 metadata를 만들고 validation,
   serialization, form, admin, OpenAPI가 이를 읽는다. Django model처럼 전역 registry를
   암묵적으로 수정하지 않는다.
3. **Admin은 metadata 기반이지만 실험 기능:** CRUD, 권한, audit, template override는
   제공하지만 Django admin의 자동 model discovery, package registry, 모든 widget 생태계를
   동일하게 제공하지 않는다.
   등록·운영·템플릿 override 방법은 [Admin 가이드](admin.md), [운영 가이드](admin-operations.md), [템플릿 가이드](admin-template-customization.md)를 확인한다.
4. **외부 provider는 프로젝트가 선택:** PostgreSQL, Redis/Valkey, S3-compatible,
   SMTP, broker는 contract/adapter가 있어도 credential·retry·live 운영 증거는 프로젝트가
   소유한다.

## 현재 미구현 또는 별도 범위

다음은 현재 first-party 완성 기능으로 주장하지 않는다: plugin scaffold/registry 검색·설치,
동적/hot plugin loading, semantic-version dependency solver, Geo/GIS, CMS, multi-tenant,
검색, presence, GraphQL, distributed scheduler. 자세한 제한과 우회는
지원 매트릭스와 이 저장소의 문서화 계획을 따른다.

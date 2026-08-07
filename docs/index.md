# Mahanaim 문서 안내

**대상 독자:** Mahanaim을 처음 사용하는 Nim 개발자, Django/Litestar에서 이전하는 팀,
운영·확장 담당자
**안정성 기준:** 기능별 등급은 [지원 매트릭스](support-matrix.md)가 기준이다.
**검증:** `nimble docsCheck`

Mahanaim은 명시적 `Application` 구성과 계약 테스트를 중심으로 하는 Nim 웹
프레임워크다. 아래 목적에서 시작하면 필요한 문서를 빠르게 찾을 수 있다.

## 5분 안에 시작하기

1. [시작 가이드](getting-started.md)에서 프로젝트를 생성하고 첫 route를 실행한다.
2. [프로젝트 구조](project-layout.md)에서 생성된 파일과 composition root를 확인한다.
3. [CLI 레퍼런스](cli-reference.md)에서 검사·migration·OpenAPI·관리 명령을 찾는다.
4. [기능 매핑](feature-map.md)에서 Django/Litestar의 익숙한 개념에 대응하는 API를 찾는다.

## 애플리케이션 만들기

| 목표 | 문서 |
| --- | --- |
| Application·module·DI 구성 | [애플리케이션과 모듈](application-and-modules.md) |
| 환경 설정과 secret | [설정](configuration.md) |
| route·middleware·요청 검증 | [라우팅](routing.md), [요청과 검증](requests-and-validation.md) |
| HTML·JSON·스트림 응답 | [응답과 콘텐츠 협상](responses-and-negotiation.md), [업로드](uploads.md) |
| 템플릿·폼·HTMX | [템플릿](templates.md), [서버 렌더링](server-rendered-pages.md), [폼](forms.md), [HTMX](htmx.md) |
| 모델·DB·migration | 모델·migration·쿼리 가이드 (작성 예정) |
| typed API·OpenAPI | API 개발·OpenAPI 가이드 (작성 예정) |

## 보안과 관리자 기능

| 목표 | 문서 |
| --- | --- |
| 인증·계정 흐름 | 인증 가이드 (작성 예정) |
| 역할·객체 권한 | 권한 가이드 (작성 예정) |
| CSRF·CORS·TLS·rate limit | [보안 배포 점검표](security-deployment-checklist.md), 보안 가이드 (작성 예정) |
| CRUD Admin·감사 로그 | Admin·Admin 운영 가이드 (작성 예정) |
| Admin 화면 변경 | [Admin 템플릿 커스터마이징](admin-template-customization.md) |

## 비동기·실시간·저장소

| 목표 | 문서 |
| --- | --- |
| durable job·재시도·복구 | 백그라운드 작업 가이드 (작성 예정) |
| WebSocket·SSE | WebSocket·SSE 가이드 (작성 예정) |
| channel layer·Redis | 채널 레이어 가이드 (작성 예정) |
| email·flash·RSS/sitemap | 알림·신디케이션 가이드 (작성 예정) |
| upload/object storage | 저장소 가이드 (작성 예정) |
| cache·Redis/Valkey | 캐시 가이드 (작성 예정) |
| static collect | 정적 자산 가이드 (작성 예정) |

## 테스트·운영·릴리스

| 목표 | 문서 |
| --- | --- |
| 테스트 client·fixture·live gate | 테스트 가이드 (작성 예정) |
| log·trace·health·metrics | 관측성 가이드 (작성 예정) |
| Docker·nginx·systemd 배포 | [배포 레시피](deployment-recipes.md) |
| 복구·provider 운영 | [운영 가이드](operations-guide.md) |
| 지원 범위와 릴리스 절차 | [지원 매트릭스](support-matrix.md), [릴리스 지원 정책](support-policy.md) |

## 확장과 이전

| 목표 | 문서 |
| --- | --- |
| plugin·ApplicationModule | 플러그인·애플리케이션 모듈 가이드 (작성 예정) |
| adapter·확장 패키지 작성 | 확장 작성·외부 어댑터 가이드 (작성 예정) |
| Django에서 이전 | Django 전환 가이드 (작성 예정) |
| Litestar에서 이전 | Litestar 전환 가이드 (작성 예정) |
| 실험 기능·제한 | 지원 매트릭스와 알려진 제한 가이드 (작성 예정) |

## 문서 상태

이 인덱스의 링크는 사용자 문서의 정식 경로다. experimental 기능은 실제
provider 운영 검증이 더 필요할 수 있으며, 각 문서와 지원 매트릭스에서 그
제한을 함께 확인해야 한다. 문서가 코드·CLI·지원 매트릭스와 어긋나면 이슈 또는
변경 PR에서 함께 고친다.

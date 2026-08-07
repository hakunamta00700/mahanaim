# Mahanaim

Mahanaim은 Nim으로 Django와 Litestar에 견줄 수 있는 풀스택 웹 프레임워크를 설계·구현하기 위한 프로젝트입니다.

## 목표

하나의 Nim 애플리케이션에서 다음을 함께 제공하는 것을 목표로 합니다.

- 서버 사이드 렌더링, 템플릿, 폼, 관리자 화면
- 타입 안전한 API, 입력 검증, DTO, 자동 OpenAPI 문서
- ORM, migration, transaction, 인증·권한
- WebSocket, SSE, background task, 캐시와 관측성
- Prologue의 단순하고 확장 가능한 HTTP 기반

## 문서

- [풀스택 Nim 웹 프레임워크 기능 요구사항](docs/nim-fullstack-framework-requirements.md)
- [요구사항별 구현 계획과 우선순위](docs/nim-fullstack-framework-implementation-plan.md)
- [API 안정성 및 release 정책](docs/api-stability-policy.md)
- [지원 범위와 기능 성숙도](docs/support-matrix.md)
- [릴리스 지원 정책](docs/support-policy.md)
- [완료 정의](docs/definition-of-done.md)
- [실행 가능한 최소 예제](examples/minimal_app.nim)
- [Adoption 및 release 가이드](docs/adoption-and-release.md)

요구사항 문서는 Django 6.0, Litestar 2.x, Prologue의 공식 문서를 비교 기준으로 작성했습니다. 현재 저장소에는 framework-neutral core, adapter, contract test와 실행 가능한 최소 수직 슬라이스가 포함되어 있으며, 외부 staging/live 증거는 계획에서 별도로 추적합니다.

## 로드맵

1. HTTP 서버·라우팅·middleware·lifecycle 기반
2. Prologue 호환 자산과 확장 API
3. 모델·ORM·migration·transaction
4. template·form·auth·permission·admin
5. typed API·DTO·OpenAPI·WebSocket·SSE
6. 테스트 도구·보안 기본값·운영 관측성

## 라이선스

이 프로젝트는 [MIT License](LICENSE)로 배포됩니다. 이 표기는
`mahanaim.nimble`의 `license = "MIT"` 선언과 같은 설치·배포 계약이다.

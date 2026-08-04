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

요구사항 문서는 Django 6.0, Litestar 2.x, Prologue의 공식 문서를 비교 기준으로 작성했습니다. 현재 저장소는 요구사항 정의 단계이며 프레임워크 구현은 아직 시작되지 않았습니다.

## 로드맵

1. HTTP 서버·라우팅·middleware·lifecycle 기반
2. Prologue 호환 자산과 확장 API
3. 모델·ORM·migration·transaction
4. template·form·auth·permission·admin
5. typed API·DTO·OpenAPI·WebSocket·SSE
6. 테스트 도구·보안 기본값·운영 관측성

## 라이선스

아직 라이선스를 결정하지 않았습니다.

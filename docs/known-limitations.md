# 알려진 제한과 지원 경계

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**마지막 검증:** `nimble docsCheck`

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** 도입 여부와 운영 구성을 판단하는 개발자·운영자
**선행 조건:** [지원 매트릭스](support-matrix.md)의 성숙도 용어 이해
**안정성 기준:** 이 문서는 현재 지원하지 않거나 experimental인 범위를 설명하며,
기능 등급의 단일 기준은 지원 매트릭스다.
**검증:** `nimble docsCheck`

[지원 매트릭스](support-matrix.md)는 성숙도와 증거의 단일 기준이다. `stable`
계약은 표에 적힌 로컬·CI gate로 검증되며, `experimental` 기능은 표에 이름을
명시한 provider·browser·live 증거를 추가로 필요로 한다.

현재 범위 밖이거나 제공하지 않는 기능에는 plugin scaffold/registry 검색,
동적·hot plugin loading, semantic-version dependency solving, Geo/GIS, CMS,
multi-tenancy, full-text search, presence, GraphQL, 분산 scheduling이 있다.
Mahanaim은 Django식 model/app 자동 발견이나 모든 Admin widget/package와의
호환성을 약속하지 않는다.

PostgreSQL, Redis/Valkey, S3 호환 저장소, SMTP, background broker,
transport adapter, WebSocket/SSE, OpenAPI에는 provider·배포 경계가 있다.
[저장소](storage.md), [캐시](cache.md), [실시간](websocket.md),
[배포](deployment.md), [API](api-development.md) 가이드를 확인한다. 메모리 내
테스트나 compile-only 테스트만으로 외부 wire 지원 여부를 추론해서는 안 된다.

필요한 기능이 지원 범위를 벗어나면 명시적인 application-owned adapter 뒤에
통합하거나, 기존 시스템 경계를 유지한다.

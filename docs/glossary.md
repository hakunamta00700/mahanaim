# Mahanaim 용어집

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**마지막 검증:** `nimble docsCheck`

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 확장 작성자
**안정성 기준:** API 안정성은 [API 안정성 정책](api-stability-policy.md)을 따른다.
**검증:** `nimble docsCheck`

| 용어 | 뜻 |
| --- | --- |
| `Application` | route, middleware, lifecycle, security, DI, 선택 adapter를 소유하는 실행 단위다. |
| composition root | `newApplication()`을 만들고 module, provider, route, 정책을 명시적으로 조합하는 프로젝트 코드다. |
| `ApplicationModule` | imports, providers, controllers, routes, hooks, exports를 묶어 Application에 설치하는 단위다. |
| plugin | manifest와 phase를 가진 확장 단위다. Application 시작 전에 route·DI·middleware·command 등의 등록 경계를 사용한다. |
| provider | DI container가 값을 만들거나 제공하는 선언이다. application/request/task scope를 명시한다. |
| adapter | 프레임워크 계약을 특정 transport, database, cache, template engine, provider 구현에 연결하는 구현체다. |
| store | resource, object, cache, audit, job처럼 데이터를 읽고 쓰는 계약 또는 구현체다. |
| resource | metadata와 store를 연결해 CRUD·serialization·정책의 공통 경계를 제공하는 단위다. |
| route | HTTP method와 path를 handler에 연결한 Application 등록 항목이다. |
| middleware | handler 전후에서 Request/Response를 처리하는 순서 보장 구성 요소다. |
| representation | 하나의 작업 결과를 JSON, HTML, text, file, stream, SSE, WebSocket 등으로 표현한 응답 형태다. |
| content negotiation | request `Accept`와 제공 가능한 representation을 비교해 응답을 선택하는 정책이다. |
| metadata | model field, wire name, constraint, relation, sensitive 여부 등을 나타내는 공유 모델 설명이다. |
| schema | 입력 위치·타입·제약을 지정해 Request 검증과 OpenAPI에 사용하는 명시적 규칙이다. |
| DTO | API 입출력에 사용되는 타입 계약이다. 내부 모델과 요청/응답 공개 형태를 분리한다. |
| migration | DB schema를 버전 순서로 변경하는 up/down 작업이다. |
| `DatabaseSession` | transaction, isolation, connection 사용 단위를 소유하는 DB 경계다. |
| durable job | process 재시작 뒤에도 상태를 복구할 수 있도록 store에 기록하는 background job이다. |
| channel layer | WebSocket 등에서 publish/subscribe group 통신을 제공하는 추상화다. |
| live gate | 실제 DB, Redis, HTTPS endpoint처럼 외부 환경이 필요할 수 있는 선택 검증 명령이다. |
| first-party 기능 | 이 저장소가 public 계약·문서·테스트를 함께 소유하는 기능이다. |
| application-owned | 프로젝트가 credential, provider 선택, 실제 배포 topology를 소유한다는 뜻이다. 프레임워크가 추측하거나 자동 구성하지 않는다. |

## 혼동하기 쉬운 구분

- **module과 plugin:** module은 프로젝트 내 composition 도구이고, plugin은 manifest/phase/dependency를 갖는 확장 경계다.
- **adapter와 provider:** adapter는 계약의 구현체이고, provider는 그 구현체를 Application/DI에 공급하는 방법이다.
- **resource와 model:** model metadata는 데이터 모양을 설명하고, resource는 그것을 store/CRUD/응답 정책과 연결한다.
- **stable과 experimental:** stable은 지원 매트릭스에 적힌 CI/계약 증거를 통과한 공개 계약이다. experimental은 API나 실제 provider 운영 증거가 추가로 필요하다.

관련 문서: [기능 매핑](feature-map.md), [확장 작성](extension-authoring.md),
[지원 매트릭스](support-matrix.md).

# 공개 API 레퍼런스

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](../support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](../support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](../index.md) · [지원 매트릭스](../support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](../support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

이 레퍼런스는 `src/mahanaim`의 공개 `*` export와
`tests/test_public_api_compile.nim`의 컴파일 계약을 기준으로 유지합니다.
`nimble publicApiCheck`는 호환성 게이트이고, `nimble docsExamples`는 공개
최소 애플리케이션 예제를 검증합니다.

| 영역 | 레퍼런스 | 소스 경계 |
| --- | --- | --- |
| 애플리케이션과 HTTP | [Core API](core.md) | `src/mahanaim/core.nim`, `application.nim`, `router.nim` |
| 검증과 응답 | [Core API](core.md) | `validation.nim`, `response_policy.nim` |
| 확장 지점 | [확장 작성 가이드](../extension-authoring.md) | 공개 Application plugin/module API |
| 모든 umbrella export | [공개 모듈 지도](public-modules.md) | `src/mahanaim.nim` |

새 공개 export는 이 문서 또는 기능 가이드에 간단한 설명, parameter/return
계약, ownership과 lifecycle 주의, 오류 동작, 최소 예제를 함께 제공해야 합니다.
의도적으로 제외한 내부 helper는 export하지 않아야 하며, 문서화된 surface가
없는 공개 export는 문서 결함입니다.

## 전체 심볼 레퍼런스 생성

모듈별 `*` 공개 심볼의 서명과 소스 문서 주석은 Nim 문서 생성기가 단일 HTML
레퍼런스로 만듭니다. 저장소 루트에서 다음을 실행하세요.

```sh
nimble apiDocs
```

기본 출력은 `build/api-reference/theindex.html`입니다. 출력 위치를 바꾸려면
`MAHANAIM_API_DOCS_DIR`을 설정합니다. 이 생성물은 `nimble verify`에서도
만들어지므로, 잠긴 의존성과 현재 공개 API로 문서가 실제 생성되는지 항상
확인합니다. 작업 흐름, ownership, 오류 경계, 최소 실행 예제는 이 문서의
[public module map](public-modules.md)이 연결하는 canonical guide에서 함께
확인하세요.

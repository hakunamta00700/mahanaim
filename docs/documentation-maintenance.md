# Documentation maintenance

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Owners:** feature author for the changed behavior; release reviewer for final consistency.
**Review points:** before release, every public API/CLI change, and every experimental promotion.

Every feature change updates its user guide, the [documentation index](index.md),
support matrix maturity/evidence, and executable example/verification where
applicable. Update `CHANGELOG.md` with the user-visible change and link new
guides, migration cautions, or deprecation replacements.

Before merge, run `nimble docsCheck`, `nimble docsExamples`, and
`nimble publicApiCheck`; run required live gates or state their credentialed
environment evidence explicitly. Before release, reconcile support matrix,
changelog, API reference, guides, examples, and deployment limitations.

## 릴리스 전 문서 검토 체크리스트

- [ ] [지원 매트릭스](support-matrix.md)의 maturity·target·evidence가 이번
  release의 실제 gate와 일치한다.
- [ ] `CHANGELOG.md`에 사용자 영향, migration/deprecation, security 조치가
  기록돼 있다.
- [ ] 변경된 public API·CLI·기능의 가이드와 [문서 인덱스](index.md)가 갱신돼
  있으며, 실행 예제와 기대 결과가 남아 있다.
- [ ] `nimble docsCheck`, `nimble docsExamples`, `nimble publicApiCheck`와
  필요한 live gate의 결과 또는 명시적 credential skip 증거를 검토한다.
- [ ] provider·배포 제한, 비용·위험, rollback/운영 조치가 문서에 남아 있으며
  experimental 기능을 증거 없이 stable로 올리지 않는다.

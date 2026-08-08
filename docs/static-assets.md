# Static assets

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** deployers collecting CSS, JavaScript, and images.
**Verified with:** `mahanaim static collect`, `nimble test`

Run `mahanaim static collect` with an application-owned source and output policy.
The collector rejects unsafe source/output relationships and path traversal, then
copies a deterministic asset set. Do not use upload storage as the static output
directory, and do not expose writable upload paths through the static server.

Serve collected output through a reverse proxy or CDN in production. The framework
does not turn a collection result into a complete CDN cache policy: configure
immutable fingerprinted assets, cache headers, invalidation, compression, and TLS
at the serving layer. Verify that the public proxy cannot resolve paths outside
the collected output root.

Keep static artifact collection in CI/release steps and deploy the exact generated
directory or manifest with the application revision. Use a staging smoke test for
cache headers, Range/ETag behavior, and CDN invalidation.

## 로컬 실행 예제

[`examples/local_storage.nim`](../examples/local_storage.nim)은 임시 디렉터리에서
업로드 root와 정적 output을 분리하고, CSS 파일을 수집한 뒤 cache TTL 값을 설정한다.
다음 명령으로 실행한다.

```text
nimble docsExamples
```

`local-storage-ok`가 출력되면 local filesystem·in-memory cache 계약이 검증된
것이다. 이 예제는 S3 signing, CDN header/invalidation, Redis의 cross-process TTL을
검증하지 않는다. 그런 provider 증거는 별도 credential/staging live gate로 관리한다.

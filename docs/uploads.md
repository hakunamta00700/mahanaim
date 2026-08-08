# 업로드와 multipart 데이터

**책임 경계:** 프레임워크는 문서화된 API 계약을 제공하며, 프로젝트는 조립·설정·권한을, 외부 provider는 credential·비용·가용성을 소유한다.

**기능 상태:** [지원 매트릭스](support-matrix.md)의 해당 feature 상태를 따른다.
**지원 버전/플랫폼:** Nim `>= 2.2.0`; Windows/Linux/macOS 범위는 [지원 매트릭스](support-matrix.md)를 따른다.

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** application developers accepting user-provided files.
**Verified with:** `nimble test`

Parse the request body, select the expected multipart part, then validate and
save it through `UploadPolicy`. Storage must be outside the web/static root:
`newUploadPolicy` rejects an upload root that overlaps `webRootDirectory`.

```nim
import std/[asyncdispatch, httpcore]
import mahanaim

let uploads = newUploadPolicy(
  rootDirectory = "var/uploads",
  webRootDirectory = "public",
  maxBytes = 5 * 1024 * 1024,
  allowedContentTypes = @["image/png", "image/jpeg"],
  allowedExtensions = @[".png", ".jpg", ".jpeg"])

proc uploadAvatar(request: Request): Future[Response] {.async, gcsafe.} =
  let parsed = parseRequestBody(request)
  if not parsed.valid:
    return problemResponse(Http400, "Invalid multipart body", parsed.errorMessage)
  for part in parsed.parts:
    if part.name == "avatar" and part.filename.len > 0:
      try:
        let stored = saveUpload(part, uploads)
        return jsonResponse("{\"size\":" & $stored.size & "}", Http201)
      except UploadValidationError:
        return problemResponse(Http400, "Upload rejected", "The file does not meet this field policy")
  return problemResponse(Http400, "Upload rejected", "An avatar file is required")
```

The policy validates before writing: a filename must be one safe leaf name (no
absolute path, slash, backslash, NUL, `.` or `..`), content length must fit
`maxBytes`, and configured extension and content-type allowlists must match.
Existing files are rejected unless `overwriteExisting = true`; do not enable
overwrites for user-chosen names in a shared store.

Content type is client supplied metadata, not proof of file content. For
high-risk formats, add an application-level signature/parser check and generate
a server-side stored name. Store only an opaque identifier in public URLs and
serve or redirect after authorization; never expose the storage directory as a
static URL. Apply request-size limits at both the reverse proxy and application
boundary.

로컬에서 `UploadPolicy`, 정적 수집 경계, cache TTL을 함께 확인하려면
[`examples/local_storage.nim`](../examples/local_storage.nim)을
`nimble docsExamples`로 실행한다. 이 예제는 임시 디렉터리만 쓰며 S3/CDN/Redis
credential이나 production provider 설정을 요구하지 않는다.

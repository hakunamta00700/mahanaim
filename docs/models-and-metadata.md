# Models and metadata

**선행 조건:** Nim `>= 2.2.0`과 이 저장소 또는 설치된 Mahanaim 패키지

**관련 문서:** [문서 인덱스](index.md) · [지원 매트릭스](support-matrix.md)

**대상 독자:** Mahanaim 사용자와 유지보수자
**안정성 기준:** 기능별 상태는 [지원 매트릭스](support-matrix.md)를 따른다.
**마지막 검증:** `nimble docsCheck`

**Audience:** developers sharing one schema definition across validation, forms, OpenAPI, and storage.
**Verified with:** `nimble test`

Mahanaim uses explicit `ModelMetadata` rather than automatic global discovery.
The model macro creates deterministic field, relation, index, and constraint
metadata; application code installs the resulting model at the composition root.
Metadata is the common input for model forms, serializers, OpenAPI, and a
`DatabaseRepository`, but it does not itself open a database connection.

Use nullable and sensitive-field declarations deliberately. Nullable fields
become optional in derived input schemas; sensitive fields must stay excluded
from normal response serialization. Relations and collections are metadata
descriptions, not implicit eager loads: choose relation loading in every endpoint.

Custom fields require an explicit wire/storage mapping. Verify each custom type
in validation, serialization, OpenAPI, and its selected database adapter before
claiming portability. See [serialization](serialization.md) and
[database connections](database-connections.md). For repository boundaries,
storage adapters, and external ORM session ownership, see
[Storage/ORM integration](storage-and-orm-integration.md).

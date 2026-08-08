# Models and metadata

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

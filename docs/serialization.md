# Serialization

**Audience:** API authors translating model metadata into an explicit wire response.
**Verified with:** `nimble test`

`serializeModel`, `serializePatch`, `serializeModelGraph`, and
`serializeProjection` derive output from `ModelMetadata`. Use a projection for
each public endpoint; it prevents an internal or sensitive field from becoming a
response merely because it exists on a model.

The standard contract handles scalar JSON values and metadata-defined enum,
date/time, UUID, file, reference, and collection shapes. A custom codec belongs
in the serialization adapter registry, with a test for encode and decode failure.
Request input is not automatically a response DTO: validate input, perform the
domain work, then choose a response projection.

Never serialize password hashes, reset tokens, session data, provider credentials,
or raw upload paths. Treat renamed and deprecated response members as versioned
API contracts and document their replacement before removal.

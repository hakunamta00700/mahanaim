# Plugins

**Audience:** applications grouping optional framework integrations.
**Verified with:** `nimble test`

`PluginDefinition` pairs a `PluginManifest` with an explicit installer. The
manifest contains name, version, registration phase, and dependencies. Call
`app.use(plugin)` during application composition; dependency graph and duplicate
validation run before installation, and registration after startup is rejected.

An installer can register routes, middleware, services, serialization codecs,
storage, authentication backends, commands, or Admin extensions through the
same application APIs used by the root. It must not mutate global registries or
assume it owns an adapter supplied by another plugin/application.

There is no built-in plugin scaffold, filesystem registry/search/installation,
hot reload, dynamic loading, or semantic-version dependency solver. Distribute
plugins as ordinary Nim packages with explicit imports and composition calls.

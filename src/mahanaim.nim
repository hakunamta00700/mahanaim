## Public package entry point.
## Consumers should import this module instead of internal files where possible.

import mahanaim/[core, router, application, config, http_adapter, generator,
                 security, validation, response_policy, checks, models,
                 serialization, execution, prologue_adapter, testing,
                 body_parser, upload_storage, prologue_server, websocket_adapter,
                 model_macro, database, openapi, observability, messagepack,
                 forms, resources, di, jobs, tracing, sqlite_adapter,
                 database_pool, database_session, database_repository,
                 redis_resp, templates, model_schema, admin, query_components,
                 localization,
                 aggregate_routes, migration_commands, authorization,
                 password_hashing, seed_commands, login_throttling, release_checks,
                 account_auth, cli, idempotency, durable_jobs, static_assets,
                 storage, flash, syndication, email, controllers,
                 template_adapters, route_dsl]
import mahanaim/channels
import mahanaim/openapi_client
import mahanaim/httpx_adapter
import mahanaim/redis_channels
import mahanaim/redis_channel_layer


export core, router, application, config, http_adapter, generator, security,
       validation, response_policy, checks, models, serialization, execution,
       prologue_adapter, testing, body_parser, upload_storage, prologue_server,
       websocket_adapter, model_macro, database, openapi, observability,
       messagepack, forms, resources, di, jobs, tracing, sqlite_adapter,
       database_pool, database_session, database_repository, redis_resp,
       templates, model_schema, admin, query_components, aggregate_routes,
       localization,
       migration_commands, authorization, password_hashing, seed_commands,
       login_throttling, release_checks, account_auth, cli, idempotency,
       durable_jobs, static_assets, storage, flash, syndication, email,
       controllers, template_adapters, route_dsl
export channels
export openapi_client
export httpx_adapter
export redis_channels
export redis_channel_layer

## PostgreSQL remains available through `mahanaim/postgres_adapter` and
## `mahanaim/postgres_testing`. The umbrella import exposes it only when
## explicitly requested so SQLite-only applications do not load libpq.
when defined(mahanaimPostgres):
  import mahanaim/[postgres_adapter, postgres_testing]
  export postgres_adapter, postgres_testing

## Optional PostgreSQL integration-test fixture.
##
## The core test suite remains SQLite-only and does not require libpq or a
## server. This module is an explicit opt-in boundary: CI or a developer can
## provide SCRAM credentials through environment variables and reuse the same
## rollback fixture contract against PostgreSQL.

import std/[options, os, strutils]
import ./database
import ./postgres_adapter
import ./testing

type
  PostgresTestConfiguration* = object
    ## Password is held only in memory and is never rendered or logged.
    host*: string
    port*: int
    user*: string
    password*: string
    database*: string

proc newPostgresTestConfiguration*(host, user, password, database: string,
                                   port = 5432): PostgresTestConfiguration =
  ## Validate all connection inputs before a fixture can open a socket.
  if host.strip().len == 0 or user.strip().len == 0 or password.len == 0 or
      database.strip().len == 0:
    raise newException(ValueError,
      "PostgreSQL test configuration requires host, user, password, and database")
  if port < 1 or port > 65535:
    raise newException(ValueError, "PostgreSQL test port must be between 1 and 65535")
  PostgresTestConfiguration(host: host, port: port, user: user,
    password: password, database: database)

proc postgresTestConfigurationFromEnv*(): Option[PostgresTestConfiguration] =
  ## Return none rather than opening a connection when live credentials are
  ## absent. This makes optional integration tasks safe in normal unit CI.
  let host = getEnv("MAHANAIM_POSTGRES_HOST", "127.0.0.1")
  let portText = getEnv("MAHANAIM_POSTGRES_PORT", "5432")
  let user = getEnv("MAHANAIM_POSTGRES_USER")
  let password = getEnv("MAHANAIM_POSTGRES_PASSWORD")
  let database = getEnv("MAHANAIM_POSTGRES_DATABASE")
  if user.len == 0 or password.len == 0 or database.len == 0:
    return none(PostgresTestConfiguration)
  try:
    let port = parseInt(portText)
    some(newPostgresTestConfiguration(host, user, password, database, port))
  except ValueError:
    none(PostgresTestConfiguration)

proc newPostgresTestFixture*(configuration: PostgresTestConfiguration):
    DatabaseTestFixture =
  ## Adapt the optional PostgreSQL connection to the backend-neutral fixture.
  ## Each operation receives a transaction and is rolled back by testing.nim.
  let connection = configuration.host & ":" & $configuration.port
  let factory: DatabaseTestFactory = proc(): DatabaseAdapter {.gcsafe.} =
    newPostgresDatabaseAdapter(connection, configuration.user,
      configuration.password, configuration.database)
  let closer: DatabaseTestCloser = proc(adapter: DatabaseAdapter) {.gcsafe.} =
    cast[PostgresDatabaseAdapter](adapter).close()
  newDatabaseTestFixture(factory, closer)

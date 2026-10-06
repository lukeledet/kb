import Config

config :kb, KB.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # Ecto fills in 5432 before Postgrex reads PGPORT, so honor it here to run
  # the suite against a Postgres on another port.
  port: String.to_integer(System.get_env("PGPORT") || "5432"),
  database: "kb_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Keep the test HTTP listener off the development port so `mix test` still runs
# while a local server is up.
config :kb, :port, String.to_integer(System.get_env("TEST_PORT") || "4002")

config :logger, level: :warning

# The test repo is Postgres, so the Postgres engine has to match it. Oban 2.24
# verifies the migrated version on boot, and the Lite engine's `prefix: false`
# crashes that check.
config :kb, Oban,
  testing: :manual,
  engine: Oban.Engines.Basic

# Use fake embedder in tests to avoid hitting the network
config :arcana, embedder: KB.Test.FakeEmbedder

# No reranking in tests unless a test configures KB.Test.FakeReranker.
config :kb, :reranker, nil

# Stub the tagger so ingestion tests never call OpenRouter
config :kb, tagger: KB.Test.FakeTagger

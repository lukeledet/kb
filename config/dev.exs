import Config

config :kb, KB.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "kb_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

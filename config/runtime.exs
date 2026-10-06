import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :kb, KB.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :kb,
    secret_key_base: secret_key_base

  port = String.to_integer(System.get_env("PORT") || "4000")

  config :kb, :port, port

  # Optional llama.cpp embedding server that answers search queries, set
  # with LOCAL_EMBED_URL (see KB.Embedder.Local). A blank string counts as
  # unset (e.g. an empty `${LOCAL_EMBED_URL:-}` in docker compose), in which
  # case the default localhost:8080 endpoint applies: it fails fast and
  # routes queries to OpenRouter when no local server exists.
  case System.get_env("LOCAL_EMBED_URL", "") do
    "" -> :ok
    url -> config :kb, :local_embed_url, url
  end
end

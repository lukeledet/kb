import Config

config :kb,
  ecto_repos: [KB.Repo],
  # Parallel OpenRouter embedding requests (each covers a batch of 20 chunks)
  # issued during ingestion. Lower this if OpenRouter rate-limits (429s).
  embed_max_concurrency: 8,
  # OpenRouter providers to try first for embeddings, fastest first. See
  # KB.Embedder.OpenRouter.routing/0.
  openrouter_provider_order: ["nebius"],
  # OpenRouter model that suggests tags for untagged sources at ingest time.
  tagger_model: "deepseek/deepseek-v4.1-flash"

# Cross-encoder that reorders hybrid search hits. On a 12-query test set,
# Voyage and Cohere's rerank-4-fast both put the right source in the top 3
# for all 12; Voyage costs a quarter as much and had the steadier tail.
# Swap the model here, or set it to nil to turn reranking off.
config :kb, :reranker, {KB.Reranker.OpenRouter, model: "voyageai/rerank-2.5"}

config :kb, KB.Repo, types: KB.PostgrexTypes

# Arcana configuration
config :arcana,
  # Routes by intent: queries to the llama.cpp server on the LAN, documents to
  # OpenRouter. See `KB.Embedder`.
  embedder: KB.Embedder,
  chunk_size: 450,
  chunk_overlap: 50,
  vector_dimensions: 4096

config :kb, Oban,
  repo: KB.Repo,
  # sync indexes keyed documents (wiki pages), which callers often wait on,
  # so it never queues behind a book in ingestion.
  queues: [ingestion: 2, sync: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]

import_config "#{config_env()}.exs"

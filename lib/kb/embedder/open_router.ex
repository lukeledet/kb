defmodule KB.Embedder.OpenRouter do
  @behaviour Arcana.Embedder

  alias KB.Embedder.OpenAI

  @moduledoc """
  Qwen3-Embedding-8B through OpenRouter's hosted endpoint.

  This is the backend for document embeddings, which run in background Oban
  jobs where throughput matters more than latency: it embeds 20 chunks per
  request and runs several requests at once. Query embeddings go to
  `KB.Embedder.Local` instead, because OpenRouter's latency for a single short
  input is unpredictable. `KB.Embedder` picks between them.
  """

  @api_url "https://openrouter.ai/api/v1/embeddings"
  @model "qwen/qwen3-embedding-8b"
  @batch_size 20
  @default_max_concurrency 8

  # Query embeddings block an interactive search, so they get a tight budget.
  # Document embeddings run in background Oban jobs, where slow-but-successful
  # beats fast-but-failed, so they keep the generous one. Arcana tags every
  # call with `intent: :query` or `intent: :document`.
  @query_timeout 10_000
  @query_max_retries 1
  @document_timeout 120_000
  @document_max_retries 3

  @impl true
  def embed(text, opts \\ []), do: OpenAI.embed(config(), text, opts)

  @impl true
  def embed_batch(texts, opts \\ []), do: OpenAI.embed_batch(config(), texts, opts)

  @impl true
  def dimensions(_opts \\ []), do: 4096

  @doc """
  Request budget for an embedding call, as `{receive_timeout, max_retries}`.

  Public so the policy is assertable: tests drive the embedder through a
  `:plug`, which bypasses the HTTP transport these values govern.
  """
  def request_budget(opts) do
    if Keyword.get(opts, :intent) == :query do
      {@query_timeout, @query_max_retries}
    else
      {@document_timeout, @document_max_retries}
    end
  end

  defp config do
    %{
      url: @api_url,
      model: @model,
      api_key: &api_key/0,
      batch_size: @batch_size,
      max_concurrency: &max_concurrency/0,
      budget: &request_budget/1,
      body: &routing/1
    }
  end

  @doc """
  OpenRouter provider routing for a request.

  OpenRouter spreads this model across several providers whose latency
  differs widely and changes by the hour: on 2026-09-29 Nebius answered
  one-chunk requests in about 0.5 s while DeepInfra took 1.7 to 9.7 s, and
  that afternoon DeepInfra answered in 0.2 to 0.9 s while Nebius took up to
  1.4 s. Their vectors agree to a cosine of 0.9999, so the choice changes
  nothing about the embedding space.

  With `provider: name` in `opts`, the request goes to that provider only,
  so a caller can race providers against each other. Otherwise it tries
  `config :kb, :openrouter_provider_order` first, with fallbacks on so an
  outage costs latency, not failures.
  """
  def routing(opts \\ []) do
    case {Keyword.get(opts, :provider), Application.get_env(:kb, :openrouter_provider_order, [])} do
      {nil, []} -> %{}
      {nil, order} -> %{provider: %{order: order, allow_fallbacks: true}}
      {provider, _} -> %{provider: %{order: [provider], allow_fallbacks: false}}
    end
  end

  defp api_key do
    System.get_env("OPENROUTER_API_KEY") ||
      raise "OPENROUTER_API_KEY environment variable is not set"
  end

  # How many @batch_size-sized requests to run in parallel. Tunable via
  # `config :kb, :embed_max_concurrency` to stay within OpenRouter rate limits.
  defp max_concurrency do
    Application.get_env(:kb, :embed_max_concurrency, @default_max_concurrency)
  end
end

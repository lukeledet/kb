defmodule KB.Embedder.Local do
  @behaviour Arcana.Embedder

  alias KB.Embedder.OpenAI

  @moduledoc """
  Qwen3-Embedding-8B on a llama.cpp server on the LAN. The endpoint comes
  from `LOCAL_EMBED_URL` (`config :kb, :local_embed_url`), defaulting to
  `http://localhost:8080/v1/embeddings`.

  Same model and same 4096 dimensions as `KB.Embedder.OpenRouter`, so the two
  produce vectors in one space and the chunks already in the database stay
  valid. It runs on CPU, which makes it slower per token but answers in a
  predictable time, and that is what an interactive search needs: OpenRouter
  returned the same one-word query in 1.0 s, 10.1 s and 23.9 s on three
  consecutive tries.

  There is no API key; keep the endpoint reachable only from trusted hosts.
  """

  @model "qwen/qwen3-embedding-8b"
  @batch_size 20
  @default_url "http://localhost:8080/v1/embeddings"

  # The server holds the weights in memory and answers a query in about 0.2 s,
  # so this is a tripwire, not a budget the normal path comes near. It is
  # deliberately tight, and retries nothing: a query that fails here falls back
  # to OpenRouter, and every second spent waiting on a server that is down or
  # restarting is added to a search that was going to succeed anyway. A
  # firewall that drops rather than refuses means a stopped server costs
  # the full timeout instead of failing at once.
  @query_timeout 5_000
  @query_max_retries 0
  @document_timeout 300_000
  @document_max_retries 2

  @impl true
  def embed(text, opts \\ []), do: OpenAI.embed(config(), text, opts)

  @impl true
  def embed_batch(texts, opts \\ []), do: OpenAI.embed_batch(config(), texts, opts)

  @impl true
  def dimensions(_opts \\ []), do: 4096

  @doc """
  Request budget for an embedding call, as `{receive_timeout, max_retries}`.
  """
  def request_budget(opts) do
    if Keyword.get(opts, :intent) == :query do
      {@query_timeout, @query_max_retries}
    else
      {@document_timeout, @document_max_retries}
    end
  end

  @doc """
  Endpoint of the llama.cpp server, from `config :kb, :local_embed_url`.
  """
  def url, do: Application.get_env(:kb, :local_embed_url, @default_url)

  defp config do
    %{
      url: url(),
      model: @model,
      api_key: nil,
      batch_size: @batch_size,
      # One CPU server. Sending it more at once only queues the work behind
      # itself and makes every caller wait longer.
      max_concurrency: fn -> 1 end,
      budget: &request_budget/1
    }
  end
end

defmodule KB.Embedder do
  @behaviour Arcana.Embedder

  require Logger

  alias KB.Embedder.Local
  alias KB.Embedder.OpenRouter
  alias KB.Embedder.QueryCache
  alias KB.Search.Stats

  @moduledoc """
  Picks an embedding backend from what the caller is embedding.

  Arcana tags every call with `intent: :query` or `intent: :document`, and the
  two want opposite things:

    * A **query** blocks an interactive search, so it races the llama.cpp
      server on the LAN (`KB.Embedder.Local`) against OpenRouter, as below.

    * A **document** is embedded by a background Oban job, where throughput
      decides how long an ingest takes, so it goes to OpenRouter
      (`KB.Embedder.OpenRouter`), which embeds 20 chunks per request and runs
      several requests at once.

  Both run Qwen3-Embedding-8B at 4096 dimensions, so the vectors land in one
  space no matter which side produced them.

  A query goes to the LAN server and to two OpenRouter providers at once,
  plus one more OpenRouter request if none has answered in 500 ms, and the
  first answer wins. A stopped or restarting
  container costs nothing, and neither backend's slow moments decide a
  search's latency. Set `config :kb, :query_embedder` to pin one backend.
  """

  # A query goes to each of these OpenRouter providers directly, and to any
  # provider after this long if nothing has answered.
  @query_providers ["nebius", "deepinfra"]
  @query_hedge_after 500

  @impl true
  def embed(text, opts \\ []) do
    case backend(opts) do
      :race -> race(text, opts)
      module -> module.embed(text, opts)
    end
  end

  # Batches are documents in practice, and a race is only for single queries.
  @impl true
  def embed_batch(texts, opts \\ []) do
    case backend(opts) do
      :race -> OpenRouter.embed_batch(texts, opts)
      module -> module.embed_batch(texts, opts)
    end
  end

  @impl true
  def dimensions(_opts \\ []), do: OpenRouter.dimensions()

  defp backend(opts) do
    if Keyword.get(opts, :intent) == :query do
      Application.get_env(:kb, :query_embedder, :race)
    else
      Application.get_env(:kb, :document_embedder, OpenRouter)
    end
  end

  # Measured on production (2026-09-29): the LAN embedder took 0.65 to 1.8 s
  # for a query it had not seen, and each OpenRouter provider had stretches
  # of several seconds per call, at different times of day. Racing all of
  # them is what keeps a query's embedding near the fastest one of the
  # moment. Losers finish on their own; see KB.Race.
  defp race(text, opts) do
    case QueryCache.get(text) do
      nil ->
        race_uncached(text, opts)

      embedding ->
        Stats.record_winner("cache")
        {:ok, embedding}
    end
  end

  defp race_uncached(text, opts) do
    providers =
      for provider <- Application.get_env(:kb, :query_providers, @query_providers) do
        {0,
         attempt(provider, fn ->
           OpenRouter.embed(text, Keyword.put(opts, :provider, provider))
         end)}
      end

    attempts =
      providers ++
        [
          {0, attempt("local", fn -> Local.embed(text, opts) end)},
          {@query_hedge_after, attempt("openrouter", fn -> OpenRouter.embed(text, opts) end)}
        ]

    case KB.Race.first_ok(attempts) do
      {:ok, {backend, embedding}} ->
        Stats.record_winner(backend)
        QueryCache.put(text, embedding)
        {:ok, embedding}

      {:error, reason} = error ->
        Logger.warning("query embedding failed on every backend: #{inspect(reason)}")
        error
    end
  end

  # Times an attempt for KB.Search.Stats, win or lose, and tags its result
  # with the backend so the winner can be recorded too.
  defp attempt(backend, fun) do
    fn ->
      started = System.monotonic_time(:millisecond)
      result = fun.()
      ms = System.monotonic_time(:millisecond) - started
      Stats.record_attempt(backend, ms, match?({:ok, _}, result))

      with {:ok, embedding} <- result, do: {:ok, {backend, embedding}}
    end
  end
end

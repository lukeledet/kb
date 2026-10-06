defmodule KB.Search.Stats do
  @moduledoc """
  How recent searches went, for `GET /api/stats` and the MCP stats tool.

  Search latency and quality depend on outside services whose speed changes
  by the hour. This keeps the last #{500} searches and the last #{500}
  query-embedding attempts per backend in memory, so the share of degraded
  searches and each provider's latency can be watched over time. It resets
  when the app restarts.
  """

  use GenServer

  @window 500

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records one finished search: mode, degraded, and timings."
  def record_search(search) do
    entry = %{
      mode: search.mode,
      degraded: search.degraded,
      total_ms: search.timings.total_ms,
      embed_ms: search.timings.embed_ms,
      rerank_ms: search.timings.rerank_ms
    }

    GenServer.cast(__MODULE__, {:search, entry})
  end

  @doc "Records one query-embedding attempt, whether or not it won."
  def record_attempt(backend, ms, ok?),
    do: GenServer.cast(__MODULE__, {:attempt, backend, ms, ok?})

  @doc "Records which backend answered a query embedding first."
  def record_winner(backend), do: GenServer.cast(__MODULE__, {:winner, backend})

  @doc "A summary of the recent window."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(nil), do: {:ok, %{searches: [], attempts: %{}, winners: []}}

  @impl true
  def handle_cast({:search, entry}, state) do
    {:noreply, %{state | searches: Enum.take([entry | state.searches], @window)}}
  end

  def handle_cast({:attempt, backend, ms, ok?}, state) do
    attempts =
      Map.update(state.attempts, backend, [{ms, ok?}], &Enum.take([{ms, ok?} | &1], @window))

    {:noreply, %{state | attempts: attempts}}
  end

  def handle_cast({:winner, backend}, state) do
    {:noreply, %{state | winners: Enum.take([backend | state.winners], @window)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, summarize(state), state}
  end

  defp summarize(%{searches: searches, attempts: attempts, winners: winners}) do
    degraded = Enum.filter(searches, &(&1.degraded != []))

    %{
      searches: length(searches),
      by_mode: Enum.frequencies_by(searches, & &1.mode),
      degraded_share: share(length(degraded), length(searches)),
      degraded_by_reason: searches |> Enum.flat_map(& &1.degraded) |> Enum.frequencies(),
      total_ms: percentiles(Enum.map(searches, & &1.total_ms)),
      embed_ms: percentiles(for %{embed_ms: ms} <- searches, ms != nil, do: ms),
      rerank_ms: percentiles(for %{rerank_ms: ms} <- searches, ms != nil, do: ms),
      query_embedding: %{
        winners: Enum.frequencies(winners),
        backends:
          Map.new(attempts, fn {backend, list} ->
            ok = for {ms, true} <- list, do: ms

            {backend,
             %{attempts: length(list), errors: length(list) - length(ok)}
             |> Map.merge(percentiles(ok))}
          end)
      }
    }
  end

  defp share(_n, 0), do: 0.0
  defp share(n, total), do: Float.round(n / total, 3)

  defp percentiles([]), do: %{p50: nil, p95: nil}

  defp percentiles(values) do
    sorted = Enum.sort(values)
    at = fn q -> Enum.at(sorted, min(length(sorted) - 1, trunc(q * length(sorted)))) end
    %{p50: at.(0.5), p95: at.(0.95)}
  end
end

defmodule KB.Search.StatsTest do
  use KB.DataCase, async: false

  alias KB.Search.Stats

  setup do
    :sys.replace_state(Stats, fn _ -> %{searches: [], attempts: %{}, winners: []} end)
    :ok
  end

  test "summarizes degraded searches, latency and embedding backends" do
    for {degraded, ms} <- [
          {[], 100},
          {["embedding_slow"], 900},
          {[], 300},
          {["rerank_unavailable"], 700}
        ] do
      Stats.record_search(%{
        mode: :hybrid,
        degraded: degraded,
        timings: %{total_ms: ms, embed_ms: ms - 50, rerank_ms: nil}
      })
    end

    Stats.record_attempt("deepinfra", 200, true)
    Stats.record_attempt("deepinfra", 2_000, false)
    Stats.record_attempt("local", 900, true)
    Stats.record_winner("deepinfra")
    Stats.record_winner("cache")

    snapshot = Stats.snapshot()

    assert snapshot.searches == 4
    assert snapshot.degraded_share == 0.5
    assert snapshot.degraded_by_reason == %{"embedding_slow" => 1, "rerank_unavailable" => 1}
    assert snapshot.total_ms == %{p50: 700, p95: 900}
    assert snapshot.rerank_ms == %{p50: nil, p95: nil}
    assert snapshot.query_embedding.winners == %{"deepinfra" => 1, "cache" => 1}

    assert snapshot.query_embedding.backends["deepinfra"] == %{
             attempts: 2,
             errors: 1,
             p50: 200,
             p95: 200
           }
  end

  test "searches are recorded, and shown by GET /api/stats" do
    {:ok, _} = KB.Search.run("anything at all", mode: :keyword)
    :sys.get_state(Stats)
    assert Stats.snapshot().by_mode == %{keyword: 1}

    conn = Plug.Test.conn(:get, "/api/stats") |> KB.Router.call(KB.Router.init([]))
    assert %{"search" => %{"searches" => 1}} = Jason.decode!(conn.resp_body)
  end
end

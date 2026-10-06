defmodule KB.Reranker.OpenRouterTest do
  use ExUnit.Case, async: false

  alias KB.Reranker.OpenRouter

  setup do
    System.put_env("OPENROUTER_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)
  end

  defp answer(conn, results) do
    Req.Test.json(conn, %{"results" => results, "usage" => %{"cost" => 0.00008}})
  end

  test "sends the model, query and passages, and returns results best first" do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "model" => "voyageai/rerank-2.5",
               "query" => "q",
               "documents" => ["a", "b"]
             }

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

      answer(conn, [
        %{"index" => 0, "relevance_score" => 0.2},
        %{"index" => 1, "relevance_score" => 0.9}
      ])
    end

    assert {:ok, [%{index: 1, score: 0.9}, %{index: 0, score: 0.2}]} =
             OpenRouter.rerank("q", ["a", "b"], model: "voyageai/rerank-2.5", plug: plug)
  end

  test "hedges a slow request" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    plug = fn conn ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: Process.sleep(2_000)
      answer(conn, [%{"index" => 0, "relevance_score" => 0.5}])
    end

    {us, result} =
      :timer.tc(fn ->
        OpenRouter.rerank("q", ["a"], model: "m", plug: plug, hedge_after: 50, timeout: 1_000)
      end)

    assert {:ok, [%{index: 0}]} = result
    assert us < 900_000
  end

  test "gives up at the deadline" do
    plug = fn conn ->
      Process.sleep(1_000)
      answer(conn, [])
    end

    assert {:error, :timeout} =
             OpenRouter.rerank("q", ["a"], model: "m", plug: plug, hedge_after: nil, timeout: 100)
  end

  test "reports an API error" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 400, ~s({"error": "bad model"})) end

    assert {:error, {:api_error, 400, _}} =
             OpenRouter.rerank("q", ["a"], model: "m", plug: plug, hedge_after: nil)
  end

  test "reranks nothing without a request" do
    assert {:ok, []} = OpenRouter.rerank("q", [], model: "m")
  end
end

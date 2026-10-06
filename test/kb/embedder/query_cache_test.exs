defmodule KB.Embedder.QueryCacheTest do
  use ExUnit.Case, async: false

  alias KB.Embedder.QueryCache

  test "returns a cached embedding at 4-byte precision" do
    QueryCache.put("cache test query", [0.5, -0.25, 1.0])
    :sys.get_state(QueryCache)
    assert QueryCache.get("cache test query") == [0.5, -0.25, 1.0]
    assert QueryCache.get("never cached") == nil
  end

  test "a repeated query skips every backend" do
    System.put_env("OPENROUTER_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)
    test = self()

    plug = fn conn ->
      send(test, :called)

      Req.Test.json(conn, %{"data" => [%{"embedding" => List.duplicate(0.5, 4096), "index" => 0}]})
    end

    text = "repeat me #{System.unique_integer()}"
    assert {:ok, _} = KB.Embedder.embed(text, intent: :query, plug: plug)
    assert_receive :called
    :sys.get_state(QueryCache)
    flush()

    assert {:ok, embedding} = KB.Embedder.embed(text, intent: :query, plug: plug)
    assert length(embedding) == 4096
    refute_receive :called, 200
  end

  defp flush do
    receive do
      :called -> flush()
    after
      300 -> :ok
    end
  end
end

defmodule KB.Embedder.OpenRouterTest do
  use ExUnit.Case, async: true

  alias KB.Embedder.OpenRouter

  @dims 4096

  setup do
    System.put_env("OPENROUTER_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)
    :ok
  end

  defp make_embedding(dims \\ @dims) do
    Enum.map(1..dims, fn i -> i * 0.001 end)
  end

  defp success_plug(embeddings) do
    fn conn ->
      data =
        embeddings
        |> Enum.with_index()
        |> Enum.map(fn {emb, i} -> %{"embedding" => emb, "index" => i} end)

      Req.Test.json(conn, %{"data" => data, "model" => "qwen/qwen3-embedding-8b"})
    end
  end

  defp error_plug(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  describe "embed/2" do
    test "returns embedding vector on success" do
      embedding = make_embedding()
      plug = success_plug([embedding])

      assert {:ok, result} = OpenRouter.embed("hello world", plug: plug)
      assert length(result) == @dims
    end

    test "sends correct request body" do
      embedding = make_embedding()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        assert request["model"] == "qwen/qwen3-embedding-8b"
        assert request["input"] == "hello world"

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

        data = [%{"embedding" => embedding, "index" => 0}]
        Req.Test.json(conn, %{"data" => data})
      end

      assert {:ok, _} = OpenRouter.embed("hello world", plug: plug)
    end

    test "returns error on API failure" do
      plug = error_plug(401, %{"error" => "unauthorized"})
      assert {:error, {:api_error, 401, _}} = OpenRouter.embed("hello", plug: plug)
    end
  end

  describe "embed_batch/2" do
    test "returns embeddings for multiple texts" do
      embeddings = for _ <- 1..3, do: make_embedding()
      plug = success_plug(embeddings)

      texts = ["one", "two", "three"]
      assert {:ok, results} = OpenRouter.embed_batch(texts, plug: plug)
      assert length(results) == 3
      assert Enum.all?(results, &(length(&1) == @dims))
    end

    test "batches into groups of 20" do
      call_count = :counters.new(1, [:atomics])
      embedding = make_embedding()

      plug = fn conn ->
        :counters.add(call_count, 1, 1)
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        input = request["input"]

        data =
          input
          |> Enum.with_index()
          |> Enum.map(fn {_text, i} -> %{"embedding" => embedding, "index" => i} end)

        Req.Test.json(conn, %{"data" => data})
      end

      texts = for i <- 1..25, do: "text #{i}"
      assert {:ok, results} = OpenRouter.embed_batch(texts, plug: plug)
      assert length(results) == 25
      assert :counters.get(call_count, 1) == 2
    end

    test "returns error if any batch fails" do
      plug = error_plug(500, %{"error" => "internal"})
      assert {:error, {:api_error, 500, _}} = OpenRouter.embed_batch(["one"], plug: plug)
    end

    test "preserves input order across concurrent batches" do
      # Each text is a stringified integer; the plug echoes it back in the
      # embedding's first element so we can assert results line up with inputs
      # even though batches run concurrently and may complete out of order.
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        input = Jason.decode!(body)["input"]

        data =
          input
          |> Enum.with_index()
          |> Enum.map(fn {text, i} ->
            value = String.to_integer(text)
            %{"embedding" => [value / 1 | List.duplicate(0.0, @dims - 1)], "index" => i}
          end)

        Req.Test.json(conn, %{"data" => data})
      end

      texts = Enum.map(1..45, &Integer.to_string/1)
      assert {:ok, results} = OpenRouter.embed_batch(texts, plug: plug)
      assert length(results) == 45
      assert Enum.map(results, fn [first | _] -> round(first) end) == Enum.to_list(1..45)
    end
  end

  describe "dimensions/1" do
    test "returns 4096" do
      assert OpenRouter.dimensions([]) == @dims
    end
  end

  describe "request_budget/1" do
    test "queries get a budget that fits inside the MCP transport's 30s timeout" do
      {timeout, max_retries} = OpenRouter.request_budget(intent: :query)

      # Worst case is every attempt burning the full timeout, and it still has
      # to leave room for the tool to report a clean error before the
      # Streamable HTTP transport abandons its call to the MCP server.
      assert timeout * (max_retries + 1) < 30_000
    end

    test "documents get a longer budget than queries" do
      {query_timeout, query_retries} = OpenRouter.request_budget(intent: :query)
      {doc_timeout, doc_retries} = OpenRouter.request_budget(intent: :document)

      assert doc_timeout > query_timeout
      assert doc_retries > query_retries
    end

    test "defaults to the document budget when intent is unset" do
      assert OpenRouter.request_budget([]) == OpenRouter.request_budget(intent: :document)
    end

    test "query intent still embeds normally" do
      plug = success_plug([make_embedding()])

      assert {:ok, result} = OpenRouter.embed("hello", plug: plug, intent: :query)
      assert length(result) == @dims
    end
  end

  describe "provider routing" do
    test "asks OpenRouter to try the configured providers first" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body)["provider"] == %{
                 "order" => ["nebius"],
                 "allow_fallbacks" => true
               }

        success_plug([make_embedding()]).(conn)
      end

      assert {:ok, _} = OpenRouter.embed("hello", plug: plug)
    end

    test "sends a request to one provider only when asked to" do
      assert OpenRouter.routing(provider: "deepinfra") ==
               %{provider: %{order: ["deepinfra"], allow_fallbacks: false}}
    end
  end

  describe "hedged requests" do
    # Answers the first request after `delay` ms and later ones at once, so a
    # hedge that fires wins the race.
    defp slow_first_plug(delay) do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fn conn ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: Process.sleep(delay)
        success_plug([make_embedding()]).(conn)
      end
    end

    test "a second request answers when the first is slow" do
      plug = slow_first_plug(2_000)

      {elapsed, result} =
        :timer.tc(fn -> OpenRouter.embed_batch(["hello"], plug: plug, hedge_after: 50) end)

      assert {:ok, [embedding]} = result
      assert length(embedding) == @dims
      assert elapsed < 1_500_000
    end

    test "a fast first answer sends no second request" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        Agent.update(calls, &(&1 + 1))
        success_plug([make_embedding()]).(conn)
      end

      assert {:ok, [_]} = OpenRouter.embed_batch(["hello"], plug: plug, hedge_after: 1_000)
      assert Agent.get(calls, & &1) == 1
    end

    test "returns the error when every request fails" do
      plug = error_plug(500, %{"error" => "down"})

      assert {:error, {:api_error, 500, _}} =
               OpenRouter.embed_batch(["hello"], plug: plug, hedge_after: 0)
    end
  end
end

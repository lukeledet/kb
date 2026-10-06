defmodule KB.EmbedderTest do
  use ExUnit.Case, async: false

  alias KB.Embedder

  @dims 4096

  setup do
    System.put_env("OPENROUTER_API_KEY", "test-key")

    on_exit(fn ->
      System.delete_env("OPENROUTER_API_KEY")
      Application.delete_env(:kb, :query_embedder)
      Application.delete_env(:kb, :document_embedder)
    end)

    :ok
  end

  defp embedding, do: Enum.map(1..@dims, fn i -> i * 0.001 end)

  # Answers the embeddings call and records which host was asked.
  defp recording_plug(owner) do
    fn conn ->
      send(owner, {:embedded, conn.host})
      Req.Test.json(conn, %{"data" => [%{"embedding" => embedding(), "index" => 0}]})
    end
  end

  # Fails only for the local server, so a fallback to OpenRouter still answers.
  defp local_down_plug(owner) do
    fn conn ->
      send(owner, {:embedded, conn.host})

      if conn.host == "openrouter.ai" do
        Req.Test.json(conn, %{"data" => [%{"embedding" => embedding(), "index" => 0}]})
      else
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end
    end
  end

  defp failing_plug(owner) do
    fn conn ->
      send(owner, {:embedded, conn.host})
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end
  end

  # Queries are cached by text (KB.Embedder.QueryCache), so each test needs
  # its own to reach the backends.
  defp fresh_query, do: "sdlc #{System.unique_integer([:positive])}"

  defp local_host do
    Embedder.Local.url() |> URI.parse() |> Map.fetch!(:host)
  end

  describe "backend routing" do
    test "a query goes to the local server and OpenRouter at once" do
      assert {:ok, _} =
               Embedder.embed(fresh_query(), intent: :query, plug: recording_plug(self()))

      local = local_host()
      assert_receive {:embedded, ^local}
      assert_receive {:embedded, "openrouter.ai"}
    end

    test "a document goes to OpenRouter" do
      assert {:ok, _} = Embedder.embed("a chunk", intent: :document, plug: recording_plug(self()))
      assert_received {:embedded, "openrouter.ai"}
    end

    test "an untagged call is treated as a document" do
      assert {:ok, _} = Embedder.embed("a chunk", plug: recording_plug(self()))
      assert_received {:embedded, "openrouter.ai"}
    end

    test "batches go to OpenRouter, which embeds many inputs per request" do
      plug = fn conn ->
        send(self(), :unused)

        Req.Test.json(conn, %{
          "data" => [
            %{"embedding" => embedding(), "index" => 0},
            %{"embedding" => embedding(), "index" => 1}
          ]
        })
      end

      assert {:ok, [_, _]} = Embedder.embed_batch(["one", "two"], plug: plug)
    end
  end

  describe "racing a query" do
    test "answers when the local server is down" do
      assert {:ok, result} =
               Embedder.embed(fresh_query(), intent: :query, plug: local_down_plug(self()))

      assert length(result) == @dims
    end

    test "answers when OpenRouter is down" do
      local = local_host()

      plug = fn conn ->
        if conn.host == local,
          do: Req.Test.json(conn, %{"data" => [%{"embedding" => embedding(), "index" => 0}]}),
          else: Plug.Conn.send_resp(conn, 503, "unavailable")
      end

      assert {:ok, _} = Embedder.embed(fresh_query(), intent: :query, plug: plug)
    end

    test "fails only when every backend fails" do
      assert {:error, _} =
               Embedder.embed(fresh_query(), intent: :query, plug: failing_plug(self()))
    end

    test "a slow backend does not hold up the answer" do
      local = local_host()

      plug = fn conn ->
        if conn.host == local, do: Process.sleep(2_000)
        Req.Test.json(conn, %{"data" => [%{"embedding" => embedding(), "index" => 0}]})
      end

      {us, result} =
        :timer.tc(fn -> Embedder.embed(fresh_query(), intent: :query, plug: plug) end)

      assert {:ok, _} = result
      assert us < 1_000_000
    end

    test "a failed document embedding does not fall back" do
      assert {:error, _} =
               Embedder.embed("a chunk", intent: :document, plug: failing_plug(self()))

      assert_received {:embedded, "openrouter.ai"}
      refute_received {:embedded, _}
    end
  end

  describe "query budget" do
    test "a query never waits long on the local server, and never retries it" do
      {timeout, retries} = KB.Embedder.Local.request_budget(intent: :query)

      # The race is the recovery, not a retry: retries add to a search the
      # user is waiting on.
      assert retries == 0
      assert timeout <= 5_000
    end

    test "a document gets a budget long enough for a batch" do
      {timeout, _retries} = KB.Embedder.Local.request_budget(intent: :document)
      assert timeout >= 60_000
    end
  end

  describe "dimensions/1" do
    test "both backends agree, so vectors share one space" do
      assert Embedder.dimensions(intent: :query) == @dims
      assert Embedder.dimensions(intent: :document) == @dims
    end
  end

  describe "configuration" do
    test "query_embedder pins the backend for queries" do
      Application.put_env(:kb, :query_embedder, KB.Embedder.OpenRouter)

      assert {:ok, _} =
               Embedder.embed(fresh_query(), intent: :query, plug: recording_plug(self()))

      assert_received {:embedded, "openrouter.ai"}
      refute_receive {:embedded, _}, 100
    end
  end
end

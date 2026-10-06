defmodule KB.MCP.ToolsTest do
  use KB.DataCase

  alias Anubis.Server.Response
  alias KB.Sources

  @frame Anubis.Server.Frame.new()

  defp create_completed_source(attrs \\ %{}) do
    defaults = %{title: "Test Source", source_type: "text", tags: ["test"]}
    {:ok, source} = Sources.create_source(Map.merge(defaults, attrs))

    {:ok, doc} =
      Arcana.ingest("Test content for source. This has enough text to create chunks.",
        repo: KB.Repo,
        source_id: source.id,
        collection: "kb"
      )

    {:ok, source} =
      Sources.update_source(source, %{
        status: "completed",
        arcana_document_id: doc.id,
        chunk_count: doc.chunk_count
      })

    source
  end

  defp extract_json({:reply, %Response{} = resp, _frame}) do
    [%{"text" => json}] = resp.content
    Jason.decode!(json)
  end

  describe "SearchTool" do
    test "returns search results" do
      create_completed_source(%{title: "Elixir Guide", tags: ["elixir"]})

      result =
        KB.MCP.Tools.SearchTool.execute(%{query: "test content"}, @frame)
        |> extract_json()

      assert result["total"] >= 0
      assert result["mode"] == "hybrid"
      assert is_list(result["results"])
    end

    test "filters by tags" do
      create_completed_source(%{title: "Tagged", tags: ["special"]})
      create_completed_source(%{title: "Other", tags: ["other"]})

      result =
        KB.MCP.Tools.SearchTool.execute(
          %{query: "content", tags: ["special"], mode: "semantic"},
          @frame
        )
        |> extract_json()

      if length(result["results"]) > 0 do
        Enum.each(result["results"], fn r ->
          assert "special" in r["source"]["tags"]
        end)
      end
    end
  end

  describe "IngestUrlTool" do
    test "returns existing source on dedup" do
      existing =
        create_completed_source(%{url: "https://example.com/article", source_type: "url"})

      result =
        KB.MCP.Tools.IngestUrlTool.execute(%{url: "https://example.com/article"}, @frame)
        |> extract_json()

      assert result["source_id"] == existing.id
      assert result["message"] =~ "already ingested"
    end

    test "rejects invalid URL" do
      {:reply, resp, _} =
        KB.MCP.Tools.IngestUrlTool.execute(%{url: "not-a-url"}, @frame)

      assert resp.isError
    end
  end

  describe "ListSourcesTool" do
    test "returns sources with pagination" do
      for i <- 1..3, do: create_completed_source(%{title: "Source #{i}"})

      result =
        KB.MCP.Tools.ListSourcesTool.execute(%{limit: 2}, @frame)
        |> extract_json()

      assert length(result["sources"]) == 2
      assert result["total"] == 3
      assert result["has_more"] == true
    end
  end

  describe "GetSourceTool" do
    test "returns source details" do
      source = create_completed_source()

      result =
        KB.MCP.Tools.GetSourceTool.execute(%{id: source.id}, @frame)
        |> extract_json()

      assert result["id"] == source.id
      assert result["title"] == source.title
      assert result["status"] == "completed"
    end

    test "returns error for missing source" do
      {:reply, resp, _} =
        KB.MCP.Tools.GetSourceTool.execute(%{id: Ecto.UUID.generate()}, @frame)

      assert resp.isError
    end
  end

  describe "DeleteSourceTool" do
    test "deletes source" do
      source = create_completed_source()

      result =
        KB.MCP.Tools.DeleteSourceTool.execute(%{id: source.id}, @frame)
        |> extract_json()

      assert result["deleted"] == true
      assert Sources.get_source(source.id) == nil
    end

    test "returns error for missing source" do
      {:reply, resp, _} =
        KB.MCP.Tools.DeleteSourceTool.execute(%{id: Ecto.UUID.generate()}, @frame)

      assert resp.isError
    end
  end

  describe "UpdateTagsTool" do
    test "updates tags" do
      source = create_completed_source(%{tags: ["old"]})

      result =
        KB.MCP.Tools.UpdateTagsTool.execute(%{id: source.id, tags: ["new", "tags"]}, @frame)
        |> extract_json()

      assert result["tags"] == ["new", "tags"]
    end

    test "returns error for missing source" do
      {:reply, resp, _} =
        KB.MCP.Tools.UpdateTagsTool.execute(%{id: Ecto.UUID.generate(), tags: ["x"]}, @frame)

      assert resp.isError
    end
  end

  describe "ListTagsTool" do
    test "returns tags with counts" do
      create_completed_source(%{title: "A", tags: ["elixir", "otp"]})
      create_completed_source(%{title: "B", tags: ["elixir"]})

      result =
        KB.MCP.Tools.ListTagsTool.execute(%{}, @frame)
        |> extract_json()

      elixir_tag = Enum.find(result["tags"], &(&1["tag"] == "elixir"))
      assert elixir_tag["count"] == 2
    end
  end

  describe "StatsTool" do
    test "returns aggregate stats for the knowledge base" do
      create_completed_source(%{title: "A", tags: ["elixir"]})
      create_completed_source(%{title: "B", tags: ["elixir", "otp"]})
      {:ok, _pending} = Sources.create_source(%{title: "Pending", source_type: "text"})

      result =
        KB.MCP.Tools.StatsTool.execute(%{}, @frame)
        |> extract_json()

      assert result["total_sources"] == 3
      assert result["sources_by_status"]["completed"] == 2
      assert result["sources_by_status"]["pending"] == 1
      assert result["chunked_sources"] == 2
      assert result["total_chunks"] > 0
      assert result["avg_chunks_per_source"] > 0
      assert result["content_bytes"] > 0
      assert is_binary(result["content_size"])
      assert result["storage_bytes"] > 0
      assert result["unique_tags"] == 2
    end

    test "handles an empty knowledge base" do
      result =
        KB.MCP.Tools.StatsTool.execute(%{}, @frame)
        |> extract_json()

      assert result["total_sources"] == 0
      assert result["total_chunks"] == 0
      assert result["avg_chunks_per_source"] == 0
      assert result["unique_tags"] == 0
    end
  end

  describe "GetChunksTool" do
    test "returns chunks for source" do
      source = create_completed_source()

      result =
        KB.MCP.Tools.GetChunksTool.execute(%{source_id: source.id}, @frame)
        |> extract_json()

      assert result["total"] > 0
      assert is_list(result["chunks"])
    end

    test "returns error for missing source" do
      {:reply, resp, _} =
        KB.MCP.Tools.GetChunksTool.execute(%{source_id: Ecto.UUID.generate()}, @frame)

      assert resp.isError
    end
  end

  describe "FindRelatedTool" do
    test "returns related sources" do
      source_a = create_completed_source(%{title: "Source A"})
      _source_b = create_completed_source(%{title: "Source B"})

      result =
        KB.MCP.Tools.FindRelatedTool.execute(%{id: source_a.id}, @frame)
        |> extract_json()

      assert is_list(result["related"])
    end

    test "returns error for missing source" do
      {:reply, resp, _} =
        KB.MCP.Tools.FindRelatedTool.execute(%{id: Ecto.UUID.generate()}, @frame)

      assert resp.isError
    end

    test "returns error for source without chunks" do
      {:ok, source} = Sources.create_source(%{title: "Pending", source_type: "text"})

      {:reply, resp, _} =
        KB.MCP.Tools.FindRelatedTool.execute(%{id: source.id}, @frame)

      assert resp.isError
    end
  end
end

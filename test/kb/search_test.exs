defmodule KB.SearchTest do
  use KB.DataCase

  alias KB.Sources
  alias KB.Search

  setup do
    # Ingest two sources with different tags
    {:ok, source_a} =
      Sources.create_source(%{
        title: "Elixir Guide",
        source_type: "text",
        tags: ["elixir", "programming"]
      })

    {:ok, doc_a} =
      Arcana.ingest(
        "Elixir is a dynamic functional language designed for building scalable and maintainable applications. It leverages the Erlang VM known for running low-latency distributed and fault-tolerant systems.",
        repo: KB.Repo,
        source_id: source_a.id,
        collection: "kb"
      )

    {:ok, source_a} =
      Sources.update_source(source_a, %{
        status: "completed",
        arcana_document_id: doc_a.id,
        chunk_count: doc_a.chunk_count
      })

    {:ok, source_b} =
      Sources.create_source(%{
        title: "Python Handbook",
        source_type: "text",
        tags: ["python", "programming"]
      })

    {:ok, doc_b} =
      Arcana.ingest(
        "Python is a high-level general-purpose programming language. Its design philosophy emphasizes code readability with the use of significant indentation.",
        repo: KB.Repo,
        source_id: source_b.id,
        collection: "kb"
      )

    {:ok, source_b} =
      Sources.update_source(source_b, %{
        status: "completed",
        arcana_document_id: doc_b.id,
        chunk_count: doc_b.chunk_count
      })

    {:ok, source_c} =
      Sources.create_source(%{
        title: "Cooking Recipes",
        source_type: "text",
        tags: ["cooking"]
      })

    {:ok, doc_c} =
      Arcana.ingest(
        "A classic pasta recipe involves boiling water, adding salt, cooking the pasta al dente, and serving with a fresh tomato sauce and basil.",
        repo: KB.Repo,
        source_id: source_c.id,
        collection: "kb"
      )

    {:ok, source_c} =
      Sources.update_source(source_c, %{
        status: "completed",
        arcana_document_id: doc_c.id,
        chunk_count: doc_c.chunk_count
      })

    %{source_a: source_a, source_b: source_b, source_c: source_c}
  end

  describe "search/2" do
    test "semantic search returns results" do
      {:ok, results} = Search.search("programming language", mode: :semantic)
      assert length(results) > 0
    end

    test "fulltext search returns results" do
      {:ok, results} = Search.search("Elixir", mode: :fulltext)
      assert length(results) > 0
      assert Enum.any?(results, &(&1.text =~ "Elixir"))
    end

    test "hybrid search returns results" do
      {:ok, results} = Search.search("programming language", mode: :hybrid)
      assert length(results) > 0
    end

    test "tag filter returns only matching sources", %{source_a: source_a} do
      {:ok, results} = Search.search("language", tags: ["elixir"], mode: :semantic)
      assert length(results) > 0

      doc_ids = Enum.map(results, & &1.document_id)
      assert Enum.all?(doc_ids, &(&1 == source_a.arcana_document_id))
    end

    test "tag filter with programming returns both elixir and python sources", %{
      source_a: source_a,
      source_b: source_b
    } do
      {:ok, results} = Search.search("language", tags: ["programming"], mode: :semantic)
      assert length(results) > 0

      doc_ids = results |> Enum.map(& &1.document_id) |> Enum.uniq()
      assert source_a.arcana_document_id in doc_ids
      assert source_b.arcana_document_id in doc_ids
    end

    test "hybrid search with tag filter works" do
      {:ok, results} = Search.search("language", tags: ["elixir"], mode: :hybrid)
      assert length(results) > 0
    end

    test "fulltext search with tag filter works" do
      {:ok, results} = Search.search("Elixir", tags: ["elixir"], mode: :fulltext)
      assert length(results) > 0
    end

    test "respects limit" do
      {:ok, results} = Search.search("language", limit: 1, mode: :semantic)
      assert length(results) <= 1
    end

    test "no results for non-matching tags" do
      {:ok, results} = Search.search("language", tags: ["nonexistent"], mode: :semantic)
      assert results == []
    end

    for mode <- [:semantic, :fulltext, :hybrid] do
      test "#{mode} search skips chunks whose source row is gone" do
        {:ok, orphan} =
          Arcana.ingest(
            "Orphaned probe text about a programming language, left behind by a deleted source.",
            repo: KB.Repo,
            collection: "kb"
          )

        {:ok, results} = Search.search("programming language", mode: unquote(mode), limit: 50)

        refute orphan.id in Enum.map(results, & &1.document_id)
      end
    end
  end

  describe "find_related/2" do
    test "returns related sources excluding the input source", %{source_a: source_a} do
      results = Search.find_related(source_a.id)

      source_ids = Enum.map(results, & &1.source_id)
      refute source_a.id in source_ids
      assert length(results) > 0
    end

    test "returns sources ranked by similarity", %{source_a: source_a} do
      results = Search.find_related(source_a.id, limit: 5)

      scores = Enum.map(results, & &1.avg_similarity)
      assert scores == Enum.sort(scores, :desc)
    end

    test "includes expected fields in results", %{source_a: source_a} do
      [result | _] = Search.find_related(source_a.id, limit: 1)

      assert Map.has_key?(result, :source_id)
      assert Map.has_key?(result, :title)
      assert Map.has_key?(result, :source_type)
      assert Map.has_key?(result, :tags)
      assert Map.has_key?(result, :avg_similarity)
      assert Map.has_key?(result, :top_chunk_text)
    end

    test "respects limit", %{source_a: source_a} do
      results = Search.find_related(source_a.id, limit: 1)
      assert length(results) <= 1
    end

    test "raises for source without chunks" do
      {:ok, pending_source} =
        Sources.create_source(%{
          title: "Pending",
          source_type: "text"
        })

      assert_raise RuntimeError, "Source has no chunks", fn ->
        Search.find_related(pending_source.id)
      end
    end
  end
end

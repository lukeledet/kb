defmodule KB.SearchRunTest do
  # async: false because it swaps the global :arcana embedder and reranker.
  use KB.DataCase, async: false

  alias KB.{Documents, Search}

  defmodule CountingEmbedder do
    @behaviour Arcana.Embedder
    def embed(text, opts \\ []) do
      send(Application.get_env(:kb, :embed_watcher), :embedded)
      KB.Test.HashEmbedder.embed(text, opts)
    end

    def embed_batch(texts, opts \\ []), do: KB.Test.HashEmbedder.embed_batch(texts, opts)
    def dimensions(_opts \\ []), do: 4096
  end

  defmodule SlowEmbedder do
    @behaviour Arcana.Embedder
    def embed(text, opts \\ []) do
      Process.sleep(2_000)
      KB.Test.HashEmbedder.embed(text, opts)
    end

    def embed_batch(texts, opts \\ []), do: KB.Test.HashEmbedder.embed_batch(texts, opts)
    def dimensions(_opts \\ []), do: 4096
  end

  defmodule FailingEmbedder do
    @behaviour Arcana.Embedder
    def embed(_text, _opts \\ []), do: {:error, :down}
    def embed_batch(texts, opts \\ []), do: KB.Test.HashEmbedder.embed_batch(texts, opts)
    def dimensions(_opts \\ []), do: 4096
  end

  @pages %{
    "concepts/loop-memory.md" => """
    ---
    type: concept
    tags: [loops]
    ---
    # Loop memory

    State that lives on disk so each fresh pass of a loop knows where things stand.
    """,
    "concepts/prompt-injection.md" => """
    ---
    type: concept
    ---
    # Prompt injection

    The lethal trifecta: private data, untrusted content, and a way to send data out.
    """,
    "entities/stephen-toub.md" => """
    ---
    type: entity
    ---
    # Stephen Toub

    A .NET engineer who reviewed Copilot agent pull requests in dotnet runtime.
    """,
    "sources/merge-study.md" => """
    ---
    type: source
    ---
    # Many agent pull requests would not be merged

    Maintainers rejected agent pull requests for scope creep and missing tests.
    """
  }

  setup do
    prev = %{
      embedder: Application.get_env(:arcana, :embedder),
      reranker: Application.get_env(:kb, :reranker)
    }

    Application.put_env(:arcana, :embedder, KB.Test.HashEmbedder)

    on_exit(fn ->
      Application.put_env(:arcana, :embedder, prev.embedder)
      Application.put_env(:kb, :reranker, prev.reranker)
      Application.delete_env(:kb, :embed_watcher)
    end)

    for {key, text} <- @pages, do: {:ok, _} = Documents.upsert("wiki", key, text)

    {:ok, _} =
      Documents.upsert("library", "papers/merge-study.txt", merge_paper(), source_type: "text")

    Oban.drain_queue(queue: :sync)
    :ok
  end

  defp merge_paper do
    "METR merge study. Agent pull requests often fail review: maintainers reject them " <>
      "for scope creep, missing tests, and style."
  end

  defp keys(%{results: results}), do: Enum.map(results, &(&1[:key] || &1.source.key))

  describe "keyword mode" do
    test "matches a question by any of its words" do
      {:ok, search} =
        Search.run("why do agent pull requests get rejected by maintainers",
          mode: :keyword,
          group_by: :document
        )

      assert "sources/merge-study.md" in keys(search)
      assert "papers/merge-study.txt" in keys(search)
    end

    test "requires a quoted phrase" do
      {:ok, search} = Search.run(~s("lethal trifecta"), mode: :keyword, group_by: :document)
      assert keys(search) == ["concepts/prompt-injection.md"]

      {:ok, search} = Search.run(~s("trifecta lethal"), mode: :keyword)
      assert search.results == []
    end

    test "honors +required, -excluded and prefix* terms" do
      {:ok, search} = Search.run("+pull -maintainers", mode: :keyword, group_by: :document)
      assert keys(search) == ["entities/stephen-toub.md"]

      {:ok, search} = Search.run("trifect*", mode: :keyword, group_by: :document)
      assert keys(search) == ["concepts/prompt-injection.md"]
    end

    test "ranks a chunk with a rare query word above ones with a common word" do
      # "agent" is in three documents, "lethal" in one.
      {:ok, search} = Search.run("agent agent lethal", mode: :keyword, group_by: :document)
      assert hd(keys(search)) == "concepts/prompt-injection.md"
    end

    test "lifts a document whose title matches the query" do
      # Both words appear in the merge study's text; only Loop memory's title
      # has them.
      {:ok, _} =
        Documents.upsert(
          "wiki",
          "sources/loops.md",
          "# Loop notes\n\nloop loop memory memory loop memory.\n"
        )

      Oban.drain_queue(queue: :sync)
      {:ok, search} = Search.run("loop memory", mode: :keyword, group_by: :document)
      assert hd(keys(search)) == "concepts/loop-memory.md"
    end

    test "excludes whole documents in document mode, chunks in chunk mode" do
      {:ok, _} =
        Documents.upsert("wiki", "concepts/split.md", """
        # Split page

        ## One

        #{String.duplicate("The agent reviewed pull requests carefully. ", 45)}

        ## Two

        #{String.duplicate("Maintainers merged the agent work. ", 50)}
        """)

      Oban.drain_queue(queue: :sync)

      {:ok, docs} = Search.run("agent -maintainers", mode: :keyword, group_by: :document)
      refute "concepts/split.md" in keys(docs)
      refute "sources/merge-study.md" in keys(docs)

      {:ok, chunks} = Search.run("agent -maintainers", mode: :keyword)
      assert "concepts/split.md" in keys(chunks)
      refute Enum.any?(chunks.results, &(&1.text =~ "Maintainers"))

      {:ok, hybrid} = Search.run("agent -maintainers", group_by: :document)
      refute "concepts/split.md" in keys(hybrid)
    end

    test "ranks the page whose title is exactly the query first" do
      {:ok, _} =
        Documents.upsert(
          "wiki",
          "sources/gas-town-launch.md",
          "# Gas Town launch notes\n\nGas Town gas town.\n"
        )

      {:ok, _} =
        Documents.upsert("wiki", "concepts/gas-town.md", "# Gas Town\n\nAn orchestrator.\n")

      Oban.drain_queue(queue: :sync)

      {:ok, search} = Search.run("gas town", mode: :keyword, group_by: :document)
      assert hd(keys(search)) == "concepts/gas-town.md"
    end

    test "matches and reports a frontmatter author" do
      {:ok, _} =
        Documents.upsert(
          "wiki",
          "sources/runtime.md",
          "---\nauthor: Stephen Toub\n---\n# Ten months in the runtime\n\nCopilot notes, with thanks to Stephen.\n"
        )

      Oban.drain_queue(queue: :sync)

      {:ok, search} = Search.run("Stephen Toub", mode: :keyword, group_by: :document)
      hit = Enum.find(search.results, &(&1.key == "sources/runtime.md"))
      assert hit.author == "Stephen Toub"
      assert hd(keys(search)) in ["sources/runtime.md", "entities/stephen-toub.md"]
    end

    test "never calls an embedding backend" do
      Application.put_env(:arcana, :embedder, CountingEmbedder)
      Application.put_env(:kb, :embed_watcher, self())

      {:ok, search} = Search.run("loop memory", mode: :keyword)

      refute_received :embedded
      assert search.embedding_used == false
      assert search.timings.embed_ms == nil
    end

    test "returns nothing for a query of only stopwords" do
      assert {:ok, %{results: []}} = Search.run("the and of", mode: :keyword)
    end
  end

  describe "grouping and paging" do
    test "returns one hit per document with its snippet and heading path" do
      {:ok, search} = Search.run("agent pull requests", group_by: :document, limit: 10)

      assert length(keys(search)) == length(Enum.uniq(keys(search)))
      hit = Enum.find(search.results, &(&1.key == "sources/merge-study.md"))
      assert hit.title == "Many agent pull requests would not be merged"
      assert hit.collection == "wiki"
      assert hit.heading_path == ["Many agent pull requests would not be merged"]
      assert hit.frontmatter == %{"type" => "source"}
      assert hit.snippet =~ "<mark>"
      assert hit.chunk_id
      assert %DateTime{} = hit.updated_at
    end

    test "counts documents and pages through them" do
      {:ok, all} = Search.run("agent", mode: :keyword, group_by: :document, limit: 10)
      assert all.total == length(all.results)

      {:ok, first} = Search.run("agent", mode: :keyword, group_by: :document, limit: 1)

      {:ok, second} =
        Search.run("agent", mode: :keyword, group_by: :document, limit: 1, offset: 1)

      assert first.total == all.total
      assert keys(first) ++ keys(second) == Enum.take(keys(all), 2)
    end
  end

  describe "frontmatter in results" do
    setup do
      slugs = for i <- 1..40, do: "source-#{i}"

      {:ok, _} =
        Documents.upsert("wiki", "analyses/big.md", """
        ---
        type: analysis
        sources: [#{Enum.join(slugs, ", ")}]
        tags: [a, b]
        ---
        # Big analysis

        Trifecta analysis.
        """)

      Oban.drain_queue(queue: :sync)
      :ok
    end

    test "leaves out long lists and names them" do
      {:ok, search} = Search.run("trifecta analysis", mode: :keyword, group_by: :document)
      hit = Enum.find(search.results, &(&1.key == "analyses/big.md"))
      assert hit.frontmatter == %{"type" => "analysis", "tags" => ["a", "b"]}
      assert hit.frontmatter_omitted == ["sources"]
    end

    test "returns everything with full_frontmatter" do
      {:ok, search} =
        Search.run("trifecta analysis",
          mode: :keyword,
          group_by: :document,
          full_frontmatter: true
        )

      hit = Enum.find(search.results, &(&1.key == "analyses/big.md"))
      assert length(hit.frontmatter["sources"]) == 40
      refute Map.has_key?(hit, :frontmatter_omitted)
    end
  end

  describe "filters" do
    test "by collection, key prefix, frontmatter and source type" do
      {:ok, search} =
        Search.run("agent pull requests", collections: ["library"], group_by: :document)

      assert keys(search) == ["papers/merge-study.txt"]

      {:ok, search} =
        Search.run("pull requests loop trifecta",
          key_prefix: "concepts/",
          frontmatter: %{"type" => "concept"},
          group_by: :document
        )

      assert Enum.all?(keys(search), &String.starts_with?(&1, "concepts/"))
      assert keys(search) != []

      {:ok, search} = Search.run("agent", source_types: ["text"], group_by: :document)
      assert keys(search) == ["papers/merge-study.txt"]
    end

    test "warns about a collection that doesn't exist" do
      {:ok, search} = Search.run("agent", collections: ["wkii", "wiki"])
      assert search.warnings == ["unknown collection: wkii"]
      {:ok, search} = Search.run("agent")
      assert search.warnings == []
    end

    test "by updated_after" do
      future = DateTime.add(DateTime.utc_now(), 3600)
      assert {:ok, %{results: []}} = Search.run("agent", updated_after: future)
    end
  end

  describe "hybrid" do
    test "fuses keyword and semantic ranks and reports timings" do
      {:ok, search} = Search.run("loop memory", group_by: :document)

      assert hd(keys(search)) == "concepts/loop-memory.md"
      assert search.embedding_used
      assert search.degraded == []
      assert %{embed_ms: e, sql_ms: s, total_ms: t} = search.timings
      assert is_integer(e) and is_integer(s) and is_integer(t)
    end

    test "carries on with keyword candidates when embedding is slow" do
      Application.put_env(:arcana, :embedder, SlowEmbedder)

      {elapsed, {:ok, search}} =
        :timer.tc(fn -> Search.run("lethal trifecta", group_by: :document) end)

      assert search.degraded == ["embedding_slow"]
      assert search.embedding_used == false
      assert keys(search) == ["concepts/prompt-injection.md"]
      assert elapsed < 1_500_000
    end

    test "waits longer for the embedding with a larger budget" do
      Application.put_env(:arcana, :embedder, SlowEmbedder)

      {:ok, search} =
        Search.run("lethal trifecta", group_by: :document, latency_budget_ms: 3_000)

      assert search.degraded == []
      assert search.embedding_used
      assert search.timings.budget_ms == 3_000
    end

    test "carries on with keyword candidates when embedding fails" do
      Application.put_env(:arcana, :embedder, FailingEmbedder)
      {:ok, search} = Search.run("lethal trifecta", group_by: :document)
      assert search.degraded == ["embedding_unavailable"]
      assert keys(search) == ["concepts/prompt-injection.md"]
    end
  end

  describe "reranking" do
    test "reorders the top hits, then groups by document" do
      Application.put_env(
        :kb,
        :reranker,
        {KB.Test.FakeReranker, model: "fake", prefer: "Toub", notify: self()}
      )

      {:ok, search} = Search.run("agent pull requests", group_by: :document)

      assert hd(keys(search)) == "entities/stephen-toub.md"
      assert search.reranked == "fake"
      assert hd(search.results).scores.rerank == 1.0
      assert_received {:reranked, "agent pull requests", passages}
      assert Enum.any?(passages, &String.starts_with?(&1, "Title: Stephen Toub\n"))
    end

    test "takes a model for one search" do
      Application.put_env(:kb, :reranker, {KB.Test.FakeReranker, model: "fake", prefer: "Toub"})
      {:ok, search} = Search.run("agent pull requests", rerank_model: "other/model")
      assert search.reranked == "other/model"
    end

    test "is off by default for keyword search" do
      Application.put_env(:kb, :reranker, {KB.Test.FakeReranker, model: "fake", notify: self()})
      {:ok, search} = Search.run("agent", mode: :keyword)
      assert search.reranked == nil
      refute_received {:reranked, _, _}
    end

    test "keeps the fused order when the reranker fails" do
      Application.put_env(:kb, :reranker, {KB.Test.FakeReranker, model: "fake", fail: true})
      {:ok, search} = Search.run("loop memory", group_by: :document)
      assert search.degraded == ["rerank_unavailable"]
      assert hd(keys(search)) == "concepts/loop-memory.md"
      assert is_integer(search.timings.rerank_ms)
    end

    test "still reranks keyword candidates when embedding is slow" do
      Application.put_env(:arcana, :embedder, SlowEmbedder)
      Application.put_env(:kb, :reranker, {KB.Test.FakeReranker, model: "fake", prefer: "Toub"})

      {:ok, search} = Search.run("agent pull requests", group_by: :document)
      assert search.degraded == ["embedding_slow"]
      assert search.reranked == "fake"
      assert hd(keys(search)) == "entities/stephen-toub.md"
    end
  end

  describe "chunk results" do
    test "keep the original fields and add scores, heading path and snippet" do
      {:ok, [hit | _]} = Search.search("lethal trifecta", mode: :keyword)

      assert %{id: _, text: text, chunk_index: 0, document_id: _, score: score, source: source} =
               hit

      assert text =~ "trifecta"
      assert is_float(score)
      assert source.key == "concepts/prompt-injection.md"
      assert hit.snippet =~ "<mark>trifecta</mark>"
      refute hit.snippet =~ "Prompt injection\n"
    end
  end
end

defmodule KB.ContextsTest do
  use KB.DataCase, async: false

  alias KB.{Contexts, Documents, Search}

  test "sets, lists and removes notes" do
    assert {:ok, _} = Contexts.put("wiki", "", "Research wiki")
    assert {:ok, _} = Contexts.put("wiki", "sources/", "One summary page per raw source")
    assert {:ok, _} = Contexts.put("wiki", "sources/", "One page per raw source")

    assert [
             %{prefix: "", description: "Research wiki"},
             %{prefix: "sources/", description: "One page per raw source"}
           ] =
             Contexts.list("wiki")

    assert {:ok, %{description: nil}} = Contexts.put("wiki", "sources/", "")
    assert [%{prefix: ""}] = Contexts.list("wiki")
    assert {:error, _} = Contexts.put("wiki", "/abs", "x")
    assert {:error, _} = Contexts.put("wiki", "", String.duplicate("x", 501))
  end

  test "picks every note that applies to a key, general first" do
    Contexts.put("wiki", "", "Research wiki")
    Contexts.put("wiki", "sources/", "Summaries")
    Contexts.put("wiki", "sources/2026/", "This year")
    loaded = Contexts.load(["wiki"])

    assert Contexts.for_key(loaded, "wiki", "sources/2026/a.md") == [
             "Research wiki",
             "Summaries",
             "This year"
           ]

    assert Contexts.for_key(loaded, "wiki", "concepts/a.md") == ["Research wiki"]
    assert Contexts.for_key(loaded, "library", "x") == []
  end

  test "search results and documents carry their notes" do
    Contexts.put("wiki", "sources/", "One summary page per raw source")

    {:ok, _} =
      Documents.upsert("wiki", "sources/beads.md", "# Beads\n\nIssue tracker for agents.\n")

    {:ok, _} =
      Documents.upsert("wiki", "concepts/other.md", "# Other\n\nIssue tracker notes.\n")

    Oban.drain_queue(queue: :sync)

    {:ok, search} = Search.run("issue tracker", mode: :keyword, group_by: :document)
    beads = Enum.find(search.results, &(&1.key == "sources/beads.md"))
    other = Enum.find(search.results, &(&1.key == "concepts/other.md"))
    assert beads.context == ["One summary page per raw source"]
    refute Map.has_key?(other, :context)

    {:ok, [chunk | _]} = Search.search("beads", mode: :keyword)
    assert chunk.source.context == ["One summary page per raw source"]

    {:ok, source} = Documents.get("wiki", "sources/beads.md")
    assert %{context: ["One summary page per raw source"]} = Documents.with_context(%{}, source)
    assert [%{prefix: "sources/"}] = Documents.status("wiki").contexts
  end
end

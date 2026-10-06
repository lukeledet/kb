defmodule KB.LinksTest do
  use KB.DataCase, async: false

  alias KB.{Documents, Links}

  defp put(key, text, collection \\ "wiki") do
    {:ok, %{source: source}} = Documents.upsert(collection, key, text)
    Oban.drain_queue(queue: :sync)
    Repo.get!(KB.Sources.Source, source.id)
  end

  defp link_count, do: Repo.one(from l in "links", select: count(l.id))

  setup do
    put(
      "concepts/comprehension-debt.md",
      "# Comprehension debt\n\nLinks to [[loop-memory]].\n"
    )

    put(
      "concepts/loop-memory.md",
      "# Loop memory\n\nSee [[comprehension-debt]] and [[missing-page]].\n"
    )

    put(
      "sources/study.md",
      "# Study\n\n[[comprehension-debt|debt]] twice: [[Comprehension-Debt#Causes]].\n"
    )

    :ok
  end

  test "backlinks list each linking page once, with counts, aliases and headings" do
    assert [
             %{key: "concepts/loop-memory.md", count: 1},
             %{key: "sources/study.md", count: 2, aliases: ["debt"], headings: ["Causes"]}
           ] = Links.backlinks("wiki", "comprehension-debt")
  end

  test "outlinks resolve each target, and flag broken ones" do
    {:ok, source} = Documents.get("wiki", "concepts/loop-memory.md")

    assert [
             %{
               target: "comprehension-debt",
               status: "ok",
               documents: [%{"key" => "concepts/comprehension-debt.md"}]
             },
             %{target: "missing-page", status: "broken", documents: []}
           ] = Links.outlinks(source)
  end

  test "links resolve when read, so a page created later fixes them" do
    {:ok, source} = Documents.get("wiki", "concepts/loop-memory.md")
    assert Enum.any?(Links.outlinks(source), &(&1.status == "broken"))

    put("drafts/missing-page.md", "# Missing page\n")
    assert Enum.all?(Links.outlinks(source), &(&1.status == "ok"))
  end

  test "a renamed page is found by its new slug without re-indexing" do
    Documents.rename("wiki", "concepts/comprehension-debt.md", "concepts/cognitive-debt.md")
    assert Links.backlinks("wiki", "comprehension-debt") != []
    assert Links.backlinks("wiki", "cognitive-debt") == []

    {:ok, source} = Documents.get("wiki", "sources/study.md")
    assert Enum.all?(Links.outlinks(source), &(&1.status == "broken"))
  end

  test "an update replaces a page's links, and a delete removes them" do
    put("sources/study.md", "# Study\n\nNow only [[loop-memory]].\n")
    assert [%{key: "concepts/loop-memory.md"}] = Links.backlinks("wiki", "comprehension-debt")

    before = link_count()
    Documents.delete("wiki", ["sources/study.md"])
    assert link_count() == before - 1
  end

  test "the report finds broken links, orphans and ambiguous slugs" do
    put("other/loop-memory.md", "# Another loop memory\n")

    report = Links.report("wiki")

    assert report.broken == [%{key: "concepts/loop-memory.md", target: "missing-page", count: 1}]
    assert "sources/study.md" in Enum.map(report.orphans, & &1.key)
    # An ambiguous link counts for every page that shares the slug.
    refute "other/loop-memory.md" in Enum.map(report.orphans, & &1.key)

    assert report.ambiguous == [
             %{slug: "loop-memory", keys: ["concepts/loop-memory.md", "other/loop-memory.md"]}
           ]

    assert report.counts.links == 5
    assert report.counts.broken == 1
  end

  test "links stay inside their collection" do
    put("elsewhere.md", "[[comprehension-debt]]", "notes")
    assert length(Links.backlinks("wiki", "comprehension-debt")) == 2
    assert [%{key: "elsewhere.md"}] = Links.backlinks("notes", "comprehension-debt")
  end

  test "relink rebuilds links from stored text" do
    Repo.delete_all("links")
    assert Links.relink("wiki") == 3
    assert link_count() == 5
  end
end

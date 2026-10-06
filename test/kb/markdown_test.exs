defmodule KB.MarkdownTest do
  use ExUnit.Case, async: true

  alias KB.Markdown

  @page """
  ---
  type: concept
  created: 2026-09-27
  tags: [loop-engineering, memory]
  ---

  # Loop memory

  State that lives on disk.

  ## Summary

  The agent forgets, the repo doesn't.
  """

  describe "parse/1" do
    test "splits frontmatter from the body and takes the title from the first H1" do
      parsed = Markdown.parse(@page)

      assert parsed.frontmatter == %{
               "type" => "concept",
               "created" => "2026-09-27",
               "tags" => ["loop-engineering", "memory"]
             }

      assert parsed.title == "Loop memory"
      assert parsed.body =~ ~r/\A\n# Loop memory/
      refute parsed.body =~ "type: concept"
      assert parsed.warnings == []
    end

    test "prefers a frontmatter title over the H1" do
      assert Markdown.parse("---\ntitle: Real title\n---\n# Heading\n").title == "Real title"
    end

    test "treats a page without frontmatter as all body" do
      parsed = Markdown.parse("# Just a page\n\nText.\n")
      assert parsed.frontmatter == %{}
      assert parsed.body == "# Just a page\n\nText.\n"
    end

    test "accepts empty frontmatter" do
      parsed = Markdown.parse("---\n---\nBody\n")
      assert parsed.frontmatter == %{}
      assert parsed.body == "Body\n"
    end

    test "drops invalid frontmatter with a warning but keeps the body" do
      parsed = Markdown.parse("---\ntags: [unclosed\n---\n# Page\n")
      assert parsed.frontmatter == %{}
      assert parsed.body == "# Page\n"
      assert [warning] = parsed.warnings
      assert warning =~ "invalid frontmatter"
    end

    test "drops frontmatter that is not a mapping with a warning" do
      parsed = Markdown.parse("---\n- a\n- b\n---\nBody\n")
      assert parsed.frontmatter == %{}
      assert parsed.warnings == ["frontmatter is not a mapping"]
    end

    test "ignores an H1 inside a fenced code block" do
      assert Markdown.parse("```sh\n# not a title\n```\n\n# Real\n").title == "Real"
    end

    test "returns no title for a page without an H1" do
      assert Markdown.parse("## Only a subsection\n").title == nil
    end
  end

  describe "tags/1" do
    test "reads a YAML list" do
      assert Markdown.tags(%{"tags" => ["a", "b", "a", 3]}) == ["a", "b", "3"]
    end

    test "reads a comma- or space-separated string" do
      assert Markdown.tags(%{"tags" => "a, b c"}) == ["a", "b", "c"]
    end

    test "returns none when the frontmatter has no tags" do
      assert Markdown.tags(%{}) == []
    end
  end

  describe "chunk/2" do
    test "keeps a short page whole, without repeating its title" do
      %{body: body, title: title} = Markdown.parse(@page)

      assert [chunk] = Markdown.chunk(body, title)
      assert chunk.text =~ ~r/\A# Loop memory/
      assert chunk.metadata == %{"heading_path" => ["Loop memory"]}
      assert chunk.chunk_index == 0
    end

    test "prefixes a short page that has no title heading with its title" do
      assert [chunk] = Markdown.chunk("Some text.\n", "Given title")
      assert chunk.text == "Given title\n\nSome text."
    end

    test "splits a long page at headings and prefixes each chunk with its path" do
      body = """
      # Page

      Intro.

      ## First

      #{filler(1200)}

      ## Second

      ### Deep

      #{filler(1200)}
      """

      chunks = Markdown.chunk(body, "Page")

      assert Enum.map(chunks, & &1.metadata["heading_path"]) == [
               ["Page"],
               ["Page", "Second", "Deep"]
             ]

      [first, second] = chunks
      assert first.text =~ ~r/\A# Page\n\nIntro\./
      assert first.text =~ "## First"
      # The bare "## Second" heading travels with the section it opens.
      assert second.text =~ ~r/\APage > Second > Deep\n\n## Second\n\n### Deep/
      assert Enum.map(chunks, & &1.chunk_index) == [0, 1]
    end

    test "packs small sibling sections and names the path they share" do
      subsections = for i <- 1..10, do: "### Part #{i}\n\n#{filler(250)}\n\n"
      body = "# Page\n\n## Details\n\n" <> Enum.join(subsections)

      chunks = Markdown.chunk(body, "Page")

      assert length(chunks) == 2
      assert Enum.all?(chunks, &(String.length(&1.text) <= 1900))

      assert Enum.map(chunks, & &1.metadata["heading_path"]) == [
               ["Page", "Details"],
               ["Page", "Details"]
             ]
    end

    test "never packs across a ## heading" do
      body = "# Page\n\n" <> Enum.map_join(1..3, fn i -> "## S#{i}\n\n#{filler(700)}\n\n" end)

      chunks = Markdown.chunk(body, "Page")

      # "# Page" has no text of its own, so it opens the first chunk.
      assert Enum.map(chunks, & &1.metadata["heading_path"]) == [
               ["Page", "S1"],
               ["Page", "S2"],
               ["Page", "S3"]
             ]

      assert Enum.at(chunks, 0).text =~ ~r/# Page\n\n## S1/
      refute Enum.at(chunks, 0).text =~ "## S2"
    end

    test "never ends a chunk on a bare heading" do
      body =
        "# Page\n\n## Summary\n\n#{filler(1500)}\n\n## Details\n\n### First\n\n#{filler(1500)}\n"

      chunks = Markdown.chunk(body, "Page")

      for chunk <- chunks do
        last = chunk.text |> String.trim_trailing() |> String.split("\n") |> List.last()
        refute last =~ ~r/^#+ /
      end

      assert List.last(chunks).text =~ ~r/## Details\n\n### First/
    end

    test "keeps the headings of a long section on its first piece" do
      body =
        "# Page\n\n## Details\n\n### Huge\n\n" <>
          Enum.map_join(1..8, "\n\n", fn _ -> filler(600) end)

      [first | _] = Markdown.chunk(body, "Page")

      assert first.text =~ ~r/## Details\n\n### Huge\n\nword/
    end

    test "leaves ## Sources out of the chunks" do
      body = "# Page\n\n#{filler(1000)}\n\n## Sources\n\n- [[a-source]]\n- [[b-source]]\n"

      assert [chunk] = Markdown.chunk(body, "Page")
      refute chunk.text =~ "Sources"
      refute chunk.text =~ "a-source"
    end

    test "folds ## Related into the chunk before it" do
      body =
        "# Page\n\n## One\n\n#{filler(1500)}\n\n## Two\n\n#{filler(1500)}\n\n" <>
          "## Related\n\n- [[x]], [[y]], [[z]]\n"

      chunks = Markdown.chunk(body, "Page")

      assert length(chunks) == 2
      last = List.last(chunks)
      assert last.metadata["heading_path"] == ["Page", "Two"]
      assert last.text =~ ~r/## Two.*## Related\n\n- \[\[x\]\]/s
    end

    test "folds any section that is only wikilinks into the section before it" do
      body =
        "# Page\n\n## Key points\n\n#{filler(1500)}\n\n" <>
          "## Entities and concepts\n\n- Entities: [[alpha-one]], [[beta-two]]\n- Concepts: [[gamma-three]]\n\n" <>
          "## Questions raised\n\n#{filler(1500)}\n"

      chunks = Markdown.chunk(body, "Page")

      assert Enum.map(chunks, & &1.metadata["heading_path"]) == [
               ["Page", "Key points"],
               ["Page", "Questions raised"]
             ]

      assert hd(chunks).text =~ "## Entities and concepts"
      refute List.last(chunks).text =~ "Entities"
    end

    test "keeps a section with real text beside its links" do
      body =
        "# Page\n\n## One\n\n#{filler(1790)}\n\n" <>
          "## Notes\n\nSee [[alpha]] for why this matters to the rollout plan and its budget.\n"

      chunks = Markdown.chunk(body, "Page")
      assert List.last(chunks).metadata["heading_path"] == ["Page", "Notes"]
    end

    test "splits a section too big for one chunk" do
      body = "# Page\n\n## Huge\n\n" <> Enum.map_join(1..8, "\n\n", fn _ -> filler(600) end)

      chunks = Markdown.chunk(body, "Page")

      assert length(chunks) > 1
      assert Enum.all?(tl(chunks), &(&1.metadata["heading_path"] == ["Page", "Huge"]))
      assert Enum.all?(tl(chunks), &String.starts_with?(&1.text, "Page > Huge\n\n"))
    end

    test "does not split at a heading inside a fenced code block" do
      body = "# Page\n\n## Real\n\n```\n## fake\n#{filler(1900)}\n```\n"

      assert Enum.all?(
               Markdown.chunk(body, "Page"),
               &(&1.metadata["heading_path"] in [["Page"], ["Page", "Real"]])
             )
    end

    test "returns no chunks for an empty body" do
      assert Markdown.chunk("\n  \n", "Title") == []
    end
  end

  describe "section/2" do
    @doc_text """
    ---
    type: concept
    ---
    # Page

    ## Details

    ### What

    Answer.

    ## Sources

    - one
    """

    test "returns the section and its subsections, byte for byte" do
      assert Markdown.section(@doc_text, "details") ==
               {:ok, "## Details\n\n### What\n\nAnswer.\n\n"}
    end

    test "returns :error for a missing heading" do
      assert Markdown.section(@doc_text, "Nope") == :error
    end
  end

  describe "links/1" do
    test "reads every wikilink form, in order" do
      text = """
      ---
      related: "[[from-frontmatter]]"
      ---
      See [[comprehension-debt]], [[stacks-foundation|Stacks Endowment]],
      [[concepts/Scrum#Details]], ![[diagram.png]], and [[page^block]].
      """

      assert [
               %{target: "from-frontmatter", slug: "from-frontmatter", position: 0},
               %{
                 target: "comprehension-debt",
                 slug: "comprehension-debt",
                 alias: nil,
                 heading: nil,
                 embed: false
               },
               %{slug: "stacks-foundation", alias: "Stacks Endowment"},
               %{target: "concepts/Scrum", slug: "scrum", heading: "Details"},
               %{slug: "diagram.png", embed: true},
               %{target: "page", slug: "page", position: 5}
             ] = Markdown.links(text)
    end

    test "skips fenced code and same-page heading links" do
      text = "[[#local]]\n\n```\n[[in-code]]\n```\n\n~~~~\n[[also-code]]\n~~~~\nafter [[real]]\n"
      assert [%{slug: "real"}] = Markdown.links(text)
    end
  end

  describe "slug/1" do
    test "is the lowercased file name without .md" do
      assert Markdown.slug("concepts/Loop-Memory.md") == "loop-memory"
      assert Markdown.slug("overview.md") == "overview"
      assert Markdown.slug("notes/readme.txt") == "readme.txt"
    end
  end

  defp filler(chars) do
    "word " |> String.duplicate(div(chars, 5)) |> String.trim()
  end
end

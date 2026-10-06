defmodule KB.SourcesTest do
  use KB.DataCase, async: true

  alias KB.Sources
  alias KB.Sources.Source

  @valid_attrs %{title: "Shape Up", source_type: "url", tags: ["product-dev"]}

  defp create_source(attrs \\ %{}) do
    {:ok, source} = Sources.create_source(Map.merge(@valid_attrs, attrs))
    source
  end

  describe "create_source/1" do
    test "creates a source with valid attrs" do
      assert {:ok, %Source{} = source} = Sources.create_source(@valid_attrs)
      assert source.title == "Shape Up"
      assert source.source_type == "url"
      assert source.status == "pending"
      assert source.tags == ["product-dev"]
    end

    test "returns error with invalid attrs" do
      assert {:error, %Ecto.Changeset{}} = Sources.create_source(%{})
    end
  end

  describe "get_source/1 and get_source!/1" do
    test "returns source by id" do
      source = create_source()
      assert Sources.get_source(source.id).id == source.id
    end

    test "returns nil for non-existent id" do
      assert Sources.get_source(Ecto.UUID.generate()) == nil
    end

    test "get_source!/1 raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Sources.get_source!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_sources/1" do
    test "lists all sources" do
      s1 = create_source(%{title: "First"})
      s2 = create_source(%{title: "Second"})
      sources = Sources.list_sources()
      ids = Enum.map(sources, & &1.id)
      assert s1.id in ids
      assert s2.id in ids
      assert length(sources) == 2
    end

    test "filters by tags" do
      create_source(%{title: "Tagged", tags: ["elixir", "otp"]})
      create_source(%{title: "Other", tags: ["python"]})

      results = Sources.list_sources(tags: ["elixir"])
      assert length(results) == 1
      assert hd(results).title == "Tagged"
    end

    test "filters by status" do
      create_source(%{title: "Pending"})

      {:ok, completed} =
        Sources.create_source(%{title: "Done", source_type: "text", status: "completed"})

      results = Sources.list_sources(status: "completed")
      assert length(results) == 1
      assert hd(results).id == completed.id
    end

    test "supports limit and offset" do
      for i <- 1..5, do: create_source(%{title: "Source #{i}"})

      results = Sources.list_sources(limit: 2, offset: 1)
      assert length(results) == 2
    end

    test "filters by collection, which defaults to library" do
      library = create_source()
      wiki = create_source(%{title: "Page", collection: "wiki", key: "a.md"})

      assert library.collection == "library"
      assert [%Source{id: id}] = Sources.list_sources(collection: "wiki")
      assert id == wiki.id
      assert Sources.count_sources(collection: "library") == 1
      assert Sources.stats().sources_by_collection == %{"library" => 1, "wiki" => 1}
    end
  end

  describe "update_source/2" do
    test "updates source attributes" do
      source = create_source()

      assert {:ok, updated} =
               Sources.update_source(source, %{status: "completed", chunk_count: 10})

      assert updated.status == "completed"
      assert updated.chunk_count == 10
    end
  end

  describe "update_source_if_present/2" do
    test "updates like update_source/2 when the row is still there" do
      source = create_source()

      assert {:ok, updated} =
               Sources.update_source_if_present(source, %{status: "completed", chunk_count: 3})

      assert updated.status == "completed"
      assert updated.chunk_count == 3
    end

    test "reports a deleted row instead of raising" do
      source = create_source()
      {:ok, _} = Sources.delete_source(source)

      assert {:error, :source_deleted} =
               Sources.update_source_if_present(source, %{status: "completed"})
    end

    test "still returns a changeset error for invalid attrs" do
      source = create_source()

      assert {:error, %Ecto.Changeset{}} =
               Sources.update_source_if_present(source, %{status: "bogus"})
    end
  end

  describe "placeholder_title?/1" do
    test "recognizes the filename stand-in for uploads" do
      assert Sources.placeholder_title?(%Source{
               source_type: "epub",
               title: "Hard Style Abs.epub"
             })

      assert Sources.placeholder_title?(%Source{source_type: "pdf", title: "Rowing Stronger.pdf"})
      assert Sources.placeholder_title?(%Source{source_type: "epub", title: "Book.EPUB"})

      refute Sources.placeholder_title?(%Source{source_type: "epub", title: "Hard Style Abs"})
      refute Sources.placeholder_title?(%Source{source_type: "pdf", title: "Rowing Stronger"})
    end

    test "recognizes the URL stand-in" do
      url = "https://example.com/post"
      assert Sources.placeholder_title?(%Source{source_type: "url", title: url, url: url})
      refute Sources.placeholder_title?(%Source{source_type: "url", title: "A Post", url: url})
    end

    test "recognizes empty and Untitled" do
      assert Sources.placeholder_title?(%Source{source_type: "text", title: "Untitled"})
      assert Sources.placeholder_title?(%Source{source_type: "text", title: ""})
      assert Sources.placeholder_title?(%Source{source_type: "text", title: nil})
      refute Sources.placeholder_title?(%Source{source_type: "text", title: "Meeting Notes"})
    end
  end

  describe "delete_source/1" do
    test "deletes a source" do
      source = create_source()
      assert {:ok, _} = Sources.delete_source(source)
      assert Sources.get_source(source.id) == nil
    end
  end

  describe "update_tags/2" do
    test "replaces tags" do
      source = create_source(%{tags: ["old"]})
      assert {:ok, updated} = Sources.update_tags(source, ["new", "tags"])
      assert updated.tags == ["new", "tags"]
    end
  end

  describe "list_tags/0" do
    test "returns tag counts" do
      create_source(%{title: "A", tags: ["elixir", "otp"]})
      create_source(%{title: "B", tags: ["elixir", "phoenix"]})
      create_source(%{title: "C", tags: ["python"]})

      tags = Sources.list_tags()
      assert %{tag: "elixir", count: 2} in tags
      assert %{tag: "otp", count: 1} in tags
      assert %{tag: "phoenix", count: 1} in tags
      assert %{tag: "python", count: 1} in tags
    end

    test "excludes sources with empty tags" do
      create_source(%{title: "No tags", tags: []})
      assert Sources.list_tags() == []
    end
  end

  describe "find_by_url/1" do
    test "finds source by URL" do
      source = create_source(%{url: "https://example.com/article"})
      found = Sources.find_by_url("https://example.com/article")
      assert found.id == source.id
    end

    test "returns nil for unknown URL" do
      assert Sources.find_by_url("https://unknown.com") == nil
    end
  end

  describe "find_by_content_hash/1" do
    test "finds source by content hash" do
      hash = :crypto.hash(:sha256, "some content") |> Base.encode16(case: :lower)
      source = create_source(%{content_hash: hash})
      found = Sources.find_by_content_hash(hash)
      assert found.id == source.id
    end

    test "returns nil for unknown hash" do
      assert Sources.find_by_content_hash("deadbeef") == nil
    end
  end

  describe "dedup scenarios" do
    test "URL dedup: find existing before creating" do
      url = "https://example.com/shape-up"
      existing = create_source(%{url: url})

      found = Sources.find_by_url(url)
      assert found.id == existing.id
    end

    test "content hash dedup: find existing before creating" do
      hash = :crypto.hash(:sha256, "book content") |> Base.encode16(case: :lower)
      existing = create_source(%{content_hash: hash, source_type: "pdf"})

      found = Sources.find_by_content_hash(hash)
      assert found.id == existing.id
    end

    test "force re-ingest: delete existing, create new" do
      url = "https://example.com/article"
      existing = create_source(%{url: url})
      {:ok, _} = Sources.delete_source(existing)

      assert Sources.find_by_url(url) == nil
      new = create_source(%{url: url})
      assert new.id != existing.id
    end
  end
end

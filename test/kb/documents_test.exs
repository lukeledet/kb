defmodule KB.DocumentsTest do
  # async: false because some tests swap the global :arcana embedder.
  use KB.DataCase, async: false
  use Oban.Testing, repo: KB.Repo

  alias KB.Documents
  alias KB.Sources.Source
  alias KB.Workers.SyncDocument

  defmodule FailingEmbedder do
    @behaviour Arcana.Embedder
    def embed(_text, _opts \\ []), do: {:error, :boom}
    def embed_batch(_texts, _opts \\ []), do: {:error, :boom}
    def dimensions(_opts \\ []), do: 4096
  end

  @page """
  ---
  type: concept
  tags: [loop-engineering, memory]
  ---

  # Loop memory

  State that lives on disk.
  """

  defp upsert!(key, content, opts \\ []) do
    {:ok, result} = Documents.upsert("wiki", key, content, opts)
    result
  end

  defp run_jobs, do: Oban.drain_queue(queue: :sync)

  defp chunk_texts(%Source{arcana_document_id: doc_id}) do
    Repo.all(
      from c in "arcana_chunks",
        where: c.document_id == type(^doc_id, :binary_id),
        order_by: c.chunk_index,
        select: c.text
    )
  end

  defp document_count do
    Repo.one(from d in "arcana_documents", select: count(d.id))
  end

  describe "upsert/4" do
    test "creates a keyed markdown document and queues it on the sync queue" do
      %{source: source, result: :created, warnings: []} =
        upsert!("concepts/loop-memory.md", @page)

      assert source.collection == "wiki"
      assert source.key == "concepts/loop-memory.md"
      assert source.slug == "loop-memory"
      assert source.title == "Loop memory"
      assert source.source_type == "markdown"
      assert source.tags == ["loop-engineering", "memory"]

      assert source.frontmatter == %{
               "type" => "concept",
               "tags" => ["loop-engineering", "memory"]
             }

      assert source.status == "pending"
      assert source.content_hash == Documents.hash(@page)
      assert source.arcana_document_id == nil

      assert_enqueued(
        worker: SyncDocument,
        queue: :sync,
        args: %{source_id: source.id, content_hash: source.content_hash}
      )
    end

    test "indexes the page when its job runs, without the frontmatter in chunks" do
      %{source: source} = upsert!("concepts/loop-memory.md", @page)
      assert %{success: 1} = run_jobs()

      source = Repo.get!(Source, source.id)
      assert source.status == "completed"
      assert source.chunk_count == 1
      assert [text] = chunk_texts(source)
      assert text =~ "# Loop memory"
      refute text =~ "type: concept"

      [metadata] =
        Repo.all(
          from c in "arcana_chunks",
            where: c.document_id == type(^source.arcana_document_id, :binary_id),
            select: c.metadata
        )

      assert metadata == %{"heading_path" => ["Loop memory"]}
    end

    test "reports unchanged for the same text once indexed" do
      upsert!("a.md", @page)
      run_jobs()

      assert %{result: :unchanged} = upsert!("a.md", @page)
      refute_enqueued(worker: SyncDocument, args: %{content_hash: "other"})
      assert %{success: 0} = run_jobs()
    end

    test "reports pending for the same text while it is still queued" do
      upsert!("a.md", @page)
      assert %{result: :pending} = upsert!("a.md", @page)
      assert length(all_enqueued(worker: SyncDocument)) == 1
    end

    test "queues a pending document again if its job was lost" do
      %{source: source} = upsert!("a.md", @page)
      Repo.delete_all(Oban.Job)

      assert %{result: :pending} = upsert!("a.md", @page)
      assert_enqueued(worker: SyncDocument, args: %{source_id: source.id})
    end

    test "keeps the old text searchable until the new text is indexed, then swaps" do
      %{source: source} = upsert!("a.md", "# Page\n\nold words\n")
      run_jobs()
      old = Repo.get!(Source, source.id)

      %{source: pending, result: :updated} = upsert!("a.md", "# Page\n\nnew words\n")

      # Queued, not yet indexed: same id, old document still linked.
      assert pending.id == old.id
      assert pending.status == "pending"
      assert Repo.get!(Source, source.id).arcana_document_id == old.arcana_document_id
      assert [old_text] = chunk_texts(old)
      assert old_text =~ "old words"

      run_jobs()

      new = Repo.get!(Source, source.id)
      assert new.status == "completed"
      assert new.arcana_document_id != old.arcana_document_id
      assert [new_text] = chunk_texts(new)
      assert new_text =~ "new words"

      # The old document and its chunks are gone.
      assert chunk_texts(old) == []
      assert document_count() == 1
    end

    test "moves title, tags and frontmatter with the text at the swap" do
      %{source: source} = upsert!("a.md", "---\ntype: concept\n---\n# First\n")
      run_jobs()

      upsert!("a.md", "---\ntype: entity\ntags: [x]\n---\n# Second\n")
      waiting = Repo.get!(Source, source.id)
      assert waiting.title == "First"
      assert waiting.frontmatter == %{"type" => "concept"}

      run_jobs()
      swapped = Repo.get!(Source, source.id)
      assert swapped.title == "Second"
      assert swapped.tags == ["x"]
      assert swapped.frontmatter == %{"type" => "entity", "tags" => ["x"]}
    end

    test "drops an old version whose job runs after newer text arrived" do
      %{source: source} = upsert!("a.md", "# V1\n")
      upsert!("a.md", "# V2\n")
      upsert!("a.md", "# V3\n")

      assert %{success: 1, cancelled: 2} = run_jobs()

      source = Repo.get!(Source, source.id)
      assert source.title == "V3"
      assert [text] = chunk_texts(source)
      assert text =~ "V3"
      assert document_count() == 1
    end

    test "cancels indexing a version that is no longer wanted" do
      %{source: source} = upsert!("a.md", "# V1\n")

      assert Documents.index(source.id, Documents.hash("# V0\n"), "# V0\n", %{}) ==
               {:cancel, :superseded}
    end

    test "lets an explicit title and tags add to the page's own" do
      %{source: source} = upsert!("a.md", @page, title: "Custom", tags: ["extra"])
      assert source.title == "Custom"
      assert source.tags == ["extra", "loop-engineering", "memory"]
    end

    test "treats text and transcript types as plain text" do
      %{source: source} =
        upsert!("notes/call.txt", "---\nnot: yaml\n---\nhello\n", source_type: "transcript")

      assert source.frontmatter == %{}
      assert source.title == "call"
      run_jobs()
      assert [text] = chunk_texts(Repo.get!(Source, source.id))
      assert text =~ "not: yaml"
    end

    test "reports invalid frontmatter as a warning" do
      assert %{warnings: [warning]} = upsert!("a.md", "---\ntags: [oops\n---\n# A\n")
      assert warning =~ "invalid frontmatter"
    end

    test "re-indexes the same text with force" do
      upsert!("a.md", @page)
      run_jobs()
      assert %{result: :updated} = upsert!("a.md", @page, force: true)
      assert %{success: 1} = run_jobs()
    end

    test "rejects bad input" do
      assert {:error, "collection" <> _} = Documents.upsert("Wiki!", "a.md", "x")
      assert {:error, "key must be a relative path"} = Documents.upsert("wiki", "/a.md", "x")
      assert {:error, "key must not contain . or .."} = Documents.upsert("wiki", "a/../b.md", "x")
      assert {:error, "key has an empty path segment"} = Documents.upsert("wiki", "a//b.md", "x")
      assert {:error, "content is required"} = Documents.upsert("wiki", "a.md", nil)
      assert {:error, "content is not valid UTF-8"} = Documents.upsert("wiki", "a.md", <<0xFF>>)
      assert {:error, "content contains a NUL byte"} = Documents.upsert("wiki", "a.md", "a\0b")

      assert {:error, "source_type" <> _} =
               Documents.upsert("wiki", "a.md", "x", source_type: "pdf")

      assert {:error, "tags" <> _} = Documents.upsert("wiki", "a.md", "x", tags: "a,b")
    end

    test "stores an empty document with no chunks" do
      %{source: source, result: :created} = upsert!("empty.md", "")
      assert %{success: 1} = run_jobs()

      source = Repo.get!(Source, source.id)
      assert source.status == "completed"
      assert source.chunk_count == 0
      assert source.title == "empty"
      assert {:ok, "", _hash} = Documents.content(source)

      manifest = [%{"key" => "empty.md", "content_hash" => Documents.hash("")}]
      assert {:ok, %{unchanged: 1, missing: [], stale: []}} = Documents.diff("wiki", manifest)
    end

    test "keeps the same key in different collections apart" do
      {:ok, %{source: a}} = Documents.upsert("wiki", "a.md", "# A\n")
      {:ok, %{source: b}} = Documents.upsert("other", "a.md", "# A\n")
      assert a.id != b.id
    end

    test "does not dedup keyed pages against each other or the library" do
      %{source: a} = upsert!("a.md", "# Same\n")
      %{source: b, result: :created} = upsert!("b.md", "# Same\n")
      assert a.id != b.id
      assert KB.Sources.find_by_content_hash(Documents.hash("# Same\n")) == nil
    end
  end

  defmodule RaisingEmbedder do
    @behaviour Arcana.Embedder
    def embed(_text, _opts \\ []), do: raise("embedder exploded")
    def embed_batch(_texts, _opts \\ []), do: raise("embedder exploded")
    def dimensions(_opts \\ []), do: 4096
  end

  describe "indexing failures" do
    setup do
      prev = Application.get_env(:arcana, :embedder)
      Application.put_env(:arcana, :embedder, FailingEmbedder)
      on_exit(fn -> Application.put_env(:arcana, :embedder, prev) end)
    end

    test "stays pending with the error until the last attempt, then fails" do
      %{source: source} = upsert!("a.md", @page)

      args = %{
        "source_id" => source.id,
        "content_hash" => source.content_hash,
        "content" => @page
      }

      assert {:error, _} = perform_job(SyncDocument, args, attempt: 1)
      source = Repo.get!(Source, source.id)
      assert source.status == "pending"
      assert source.error =~ "boom"

      assert {:error, _} = perform_job(SyncDocument, args, attempt: 5)
      assert Repo.get!(Source, source.id).status == "failed"
      assert document_count() == 0
    end

    test "records a crash as a failed attempt" do
      Application.put_env(:arcana, :embedder, RaisingEmbedder)
      %{source: source} = upsert!("a.md", @page)

      args = %{
        "source_id" => source.id,
        "content_hash" => source.content_hash,
        "content" => @page
      }

      assert {:error, %RuntimeError{}} = perform_job(SyncDocument, args, attempt: 5)
      source = Repo.get!(Source, source.id)
      assert source.status == "failed"
      assert source.error =~ "embedder exploded"
    end

    test "keeps the old version searchable when the new one fails" do
      Application.put_env(:arcana, :embedder, KB.Test.FakeEmbedder)
      %{source: source} = upsert!("a.md", "# Page\n\nold\n")
      run_jobs()
      old = Repo.get!(Source, source.id)

      Application.put_env(:arcana, :embedder, FailingEmbedder)
      %{source: source} = upsert!("a.md", "# Page\n\nnew\n")

      args = %{
        "source_id" => source.id,
        "content_hash" => source.content_hash,
        "content" => "# Page\n\nnew\n"
      }

      perform_job(SyncDocument, args, attempt: 5)

      failed = Repo.get!(Source, source.id)
      assert failed.status == "failed"
      assert failed.arcana_document_id == old.arcana_document_id
      assert [text] = chunk_texts(failed)
      assert text =~ "old"
    end

    test "requeues failed text when it is upserted again" do
      %{source: source} = upsert!("a.md", @page)

      args = %{
        "source_id" => source.id,
        "content_hash" => source.content_hash,
        "content" => @page
      }

      perform_job(SyncDocument, args, attempt: 5)
      Repo.delete_all(Oban.Job)

      assert %{result: :retried} = upsert!("a.md", @page)
      assert Repo.get!(Source, source.id).status == "pending"
      assert_enqueued(worker: SyncDocument, args: %{source_id: source.id})
    end
  end

  describe "delete/2" do
    test "removes documents and their chunks, and reports unknown keys" do
      %{source: source} = upsert!("a.md", @page)
      run_jobs()

      assert {:ok, %{deleted: ["a.md"], not_found: ["nope.md"]}} =
               Documents.delete("wiki", ["a.md", "nope.md"])

      assert Repo.get(Source, source.id) == nil
      assert document_count() == 0
      assert Repo.one(from c in "arcana_chunks", select: count(c.id)) == 0
    end

    test "stops a queued job for a deleted document" do
      upsert!("a.md", @page)
      Documents.delete("wiki", ["a.md"])
      assert %{cancelled: 1} = run_jobs()
      assert document_count() == 0
    end
  end

  describe "rename/3" do
    test "moves the key and slug without indexing again" do
      %{source: source} = upsert!("concepts/old-name.md", @page)
      run_jobs()
      before = Repo.get!(Source, source.id)

      assert {:ok, renamed} =
               Documents.rename("wiki", "concepts/old-name.md", "concepts/new-name.md")

      assert renamed.id == source.id
      assert renamed.key == "concepts/new-name.md"
      assert renamed.slug == "new-name"
      assert renamed.arcana_document_id == before.arcana_document_id
      assert all_enqueued(worker: SyncDocument) == []
    end

    test "refuses a missing source or a taken target" do
      upsert!("a.md", "# A\n")
      upsert!("b.md", "# B\n")
      assert {:error, :not_found} = Documents.rename("wiki", "nope.md", "c.md")
      assert {:error, :key_taken} = Documents.rename("wiki", "a.md", "b.md")
      assert {:error, "key must be a relative path"} = Documents.rename("wiki", "a.md", "/c.md")
    end
  end

  describe "diff/3" do
    setup do
      for {key, text} <- [
            {"same.md", "# Same\n"},
            {"changed.md", "# Old\n"},
            {"gone.md", "# Gone\n"}
          ] do
        upsert!(key, text)
      end

      run_jobs()
      upsert!("queued.md", "# Queued\n")
      :ok
    end

    defp entry(key, text), do: %{"key" => key, "content_hash" => Documents.hash(text)}

    test "sorts keys into missing, stale, pending, extra and unchanged" do
      manifest = [
        entry("same.md", "# Same\n"),
        entry("changed.md", "# New\n"),
        entry("queued.md", "# Queued\n"),
        entry("new.md", "# New page\n")
      ]

      assert {:ok, diff} = Documents.diff("wiki", manifest)
      assert diff.missing == ["new.md"]
      assert diff.stale == ["changed.md"]
      assert diff.pending == ["queued.md"]
      assert diff.extra == ["gone.md"]
      assert diff.unchanged == 1
      assert diff.renames == []
      assert diff.pruned == []
    end

    test "counts a failed document as stale" do
      Repo.update_all(from(s in Source, where: s.key == "same.md"), set: [status: "failed"])
      assert {:ok, %{stale: ["same.md"]}} = Documents.diff("wiki", [entry("same.md", "# Same\n")])
    end

    test "suggests a rename when an extra key holds a missing key's text" do
      manifest = [
        entry("same.md", "# Same\n"),
        entry("changed.md", "# Old\n"),
        entry("queued.md", "# Queued\n"),
        entry("moved/gone.md", "# Gone\n")
      ]

      assert {:ok, diff} = Documents.diff("wiki", manifest)
      assert diff.renames == [%{from: "gone.md", to: "moved/gone.md"}]
    end

    test "prunes extra keys and records the sync" do
      run_jobs()

      manifest = [
        entry("same.md", "# Same\n"),
        entry("changed.md", "# Old\n"),
        entry("queued.md", "# Queued\n")
      ]

      assert {:ok, diff} = Documents.diff("wiki", manifest, prune: true)
      assert diff.pruned == ["gone.md"]
      assert {:error, :not_found} = Documents.get("wiki", "gone.md")
      assert Documents.status("wiki").last_synced_at != nil
    end

    test "does not record a sync while anything is left to upload" do
      assert {:ok, _} = Documents.diff("wiki", [entry("new.md", "# New\n")], prune: false)
      assert Documents.status("wiki").last_synced_at == nil
    end

    test "refuses to prune most of a collection without force" do
      for i <- 1..10, do: upsert!("bulk/#{i}.md", "# Bulk #{i}\n")

      assert {:error, {:prune_refused, 14, 14}} = Documents.diff("wiki", [], prune: true)
      assert length(Documents.list_collections()) == 1
      assert {:ok, %{pruned: pruned}} = Documents.diff("wiki", [], prune: true, force: true)
      assert length(pruned) == 14
    end

    test "rejects a bad manifest" do
      assert {:error, "manifest must be a list"} = Documents.diff("wiki", %{})
      assert {:error, "each manifest entry" <> _} = Documents.diff("wiki", [%{"key" => "a.md"}])

      assert {:error, "content_hash for a.md" <> _} =
               Documents.diff("wiki", [%{"key" => "a.md", "content_hash" => "abc"}])

      twice = [entry("a.md", "x"), entry("a.md", "y")]
      assert {:error, "manifest lists a.md twice"} = Documents.diff("wiki", twice)
    end
  end

  describe "reading" do
    test "content/1 returns the stored text byte for byte, with its hash" do
      text = "---\ntype: concept\n---\r\n# Page\n\nUnicode: café ✓\n\n\n"
      %{source: source} = upsert!("a.md", text)
      run_jobs()

      {:ok, source} = Documents.get("wiki", "a.md")
      assert {:ok, ^text, hash} = Documents.content(source)
      assert hash == Documents.hash(text)
    end

    test "content/1 reports a document that is not indexed yet" do
      %{source: source} = upsert!("a.md", @page)
      assert {:error, :no_content} = Documents.content(source)
    end

    test "multi_get/2 reads by keys or by prefix" do
      for key <- ~w(concepts/a.md concepts/b.md entities/c.md), do: upsert!(key, "# #{key}\n")
      run_jobs()

      %{documents: docs, missing: ["concepts/zzz.md"], truncated: false} =
        Documents.multi_get("wiki", keys: ["concepts/a.md", "concepts/zzz.md"])

      assert [{%Source{key: "concepts/a.md"}, "# concepts/a.md\n"}] = docs

      %{documents: docs} = Documents.multi_get("wiki", prefix: "concepts/")
      assert Enum.map(docs, fn {s, _} -> s.key end) == ["concepts/a.md", "concepts/b.md"]

      %{documents: [_], truncated: true} = Documents.multi_get("wiki", prefix: "", limit: 1)
    end

    test "multi_get/2 treats % and _ in a prefix literally" do
      upsert!("a_b/x.md", "# X\n")
      upsert!("aXb/y.md", "# Y\n")
      %{documents: docs} = Documents.multi_get("wiki", prefix: "a_b/")
      assert Enum.map(docs, fn {s, _} -> s.key end) == ["a_b/x.md"]
    end
  end

  describe "reindex/1" do
    test "re-chunks every indexed document from its stored text, keeping its id and fields" do
      %{source: a} = upsert!("a.md", @page, title: "Custom", tags: ["extra"])
      upsert!("b.md", "# B\n")
      run_jobs()
      before = Repo.get!(Source, a.id)
      upsert!("pending.md", "# Not indexed yet\n")

      assert Documents.reindex("wiki") == 2
      assert Repo.get!(Source, a.id).status == "pending"
      assert %{success: 3} = run_jobs()

      after_ = Repo.get!(Source, a.id)
      assert after_.status == "completed"
      assert after_.arcana_document_id != before.arcana_document_id
      assert after_.title == "Custom"
      assert after_.tags == before.tags
      assert after_.content_hash == before.content_hash
      assert document_count() == 3
    end
  end

  describe "drop_collection/1" do
    test "forgets an empty collection only" do
      upsert!("a.md", @page)
      run_jobs()
      Documents.diff("wiki", [%{"key" => "a.md", "content_hash" => Documents.hash(@page)}])

      assert {:error, :not_empty} = Documents.drop_collection("wiki")
      Documents.delete("wiki", ["a.md"])
      assert Documents.status("wiki").last_synced_at != nil
      assert :ok = Documents.drop_collection("wiki")
      assert Documents.status("wiki").last_synced_at == nil
      assert {:error, :not_found} = Documents.drop_collection("wiki")
    end
  end

  describe "status/1" do
    test "counts documents, pending work and failures" do
      upsert!("a.md", "# A\n")
      run_jobs()
      upsert!("b.md", "# B\n")
      %{source: c} = upsert!("c.md", "# C\n")

      Repo.update_all(from(s in Source, where: s.id == ^c.id),
        set: [status: "failed", error: "boom"]
      )

      status = Documents.status("wiki")
      assert status.documents == 3
      assert status.pending == 1
      assert status.chunks == 1
      assert [%{key: "c.md", error: "boom"}] = status.failed
      assert status.last_changed_at != nil
    end
  end

  describe "await/2" do
    test "reports each version's final state" do
      %{source: a} = upsert!("a.md", "# A\n")
      %{source: b} = upsert!("b.md", "# B\n")
      %{source: c} = upsert!("c.md", "# C\n")
      old_c_hash = c.content_hash
      upsert!("c.md", "# C2\n")
      Documents.delete("wiki", ["b.md"])
      run_jobs()

      assert Documents.await(
               [{a.id, a.content_hash}, {b.id, b.content_hash}, {c.id, old_c_hash}],
               1_000
             ) ==
               %{a.id => "completed", b.id => "deleted", c.id => "superseded"}
    end

    test "returns the current status when time runs out" do
      %{source: a} = upsert!("a.md", "# A\n")
      assert Documents.await([{a.id, a.content_hash}], 300) == %{a.id => "pending"}
    end
  end
end

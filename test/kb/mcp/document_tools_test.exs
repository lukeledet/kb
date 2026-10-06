defmodule KB.MCP.DocumentToolsTest do
  use KB.DataCase, async: false

  alias Anubis.Server.Response
  alias KB.Documents
  alias KB.MCP.Tools

  @frame Anubis.Server.Frame.new()
  @page "---\ntype: concept\n---\n# Scrum\n\n## Origins\n\nRugby.\n"

  setup do
    Documents.upsert("wiki", "concepts/scrum.md", @page)
    Documents.upsert("wiki", "concepts/kanban.md", "# Kanban\n")
    Documents.upsert("wiki", "entities/toyota.md", "# Toyota\n")
    Oban.drain_queue(queue: :sync)
    :ok
  end

  defp reply({:reply, %Response{} = resp, _frame}) do
    [%{"text" => text}] = resp.content
    if resp.isError, do: {:error, text}, else: {:ok, Jason.decode!(text)}
  end

  describe "GetDocumentTool" do
    test "returns the text byte for byte by collection and key" do
      assert {:ok, doc} =
               Tools.GetDocumentTool.execute(
                 %{collection: "wiki", key: "concepts/scrum.md"},
                 @frame
               )
               |> reply()

      assert doc["content"] == @page
      assert doc["content_hash"] == Documents.hash(@page)
      assert doc["truncated"] == false
      assert doc["frontmatter"] == %{"type" => "concept"}
    end

    test "returns one section, and finds a document by id" do
      {:ok, source} = Documents.get("wiki", "concepts/scrum.md")

      assert {:ok, doc} =
               Tools.GetDocumentTool.execute(%{id: source.id, section: "Origins"}, @frame)
               |> reply()

      assert doc["content"] == "## Origins\n\nRugby.\n"
    end

    test "reports what it cannot find" do
      assert {:error, "No document at nope.md in wiki"} =
               Tools.GetDocumentTool.execute(%{collection: "wiki", key: "nope.md"}, @frame)
               |> reply()

      assert {:error, "Pass collection and key, or id"} =
               Tools.GetDocumentTool.execute(%{}, @frame) |> reply()

      assert {:error, "Source not found: bad"} =
               Tools.GetDocumentTool.execute(%{id: "bad"}, @frame) |> reply()
    end
  end

  describe "MultiGetTool" do
    test "fetches by prefix" do
      assert {:ok, %{"documents" => docs, "truncated" => false}} =
               Tools.MultiGetTool.execute(%{collection: "wiki", prefix: "concepts/"}, @frame)
               |> reply()

      assert Enum.map(docs, & &1["key"]) == ["concepts/kanban.md", "concepts/scrum.md"]
      assert Enum.all?(docs, &is_binary(&1["content"]))
    end

    test "fetches keys without content and reports missing ones" do
      params = %{collection: "wiki", keys: ["entities/toyota.md", "x.md"], include_content: false}

      assert {:ok, %{"documents" => [doc], "missing" => ["x.md"]}} =
               Tools.MultiGetTool.execute(params, @frame) |> reply()

      refute Map.has_key?(doc, "content")
    end

    test "needs keys or a prefix" do
      assert {:error, "Pass keys or prefix"} =
               Tools.MultiGetTool.execute(%{collection: "wiki"}, @frame) |> reply()
    end
  end

  describe "UpsertDocumentTool" do
    test "creates and then leaves unchanged" do
      params = %{collection: "wiki", key: "concepts/new.md", content: "# New\n"}

      assert {:ok, %{"result" => "created", "status" => "pending", "title" => "New"}} =
               Tools.UpsertDocumentTool.execute(params, @frame) |> reply()

      Oban.drain_queue(queue: :sync)

      assert {:ok, %{"result" => "unchanged", "status" => "completed"}} =
               Tools.UpsertDocumentTool.execute(Map.put(params, :wait, true), @frame) |> reply()
    end

    test "reports the indexed chunk count and title after waiting" do
      # The sync queue does not run on its own under test, so index from a
      # separate process while the tool waits.
      spawn(fn ->
        Process.sleep(100)
        Oban.drain_queue(queue: :sync)
      end)

      params = %{collection: "wiki", key: "concepts/scrum.md", content: "# Renamed\n", wait: true}

      assert {:ok,
              %{
                "result" => "updated",
                "status" => "completed",
                "chunk_count" => 1,
                "title" => "Renamed"
              }} =
               Tools.UpsertDocumentTool.execute(params, @frame) |> reply()
    end

    test "reports invalid input" do
      assert {:error, "key must be a relative path"} =
               Tools.UpsertDocumentTool.execute(
                 %{collection: "wiki", key: "/abs.md", content: "x"},
                 @frame
               )
               |> reply()
    end
  end

  describe "DeleteDocumentTool" do
    test "deletes by key and reports a missing key" do
      params = %{collection: "wiki", key: "concepts/kanban.md"}

      assert {:ok, %{"deleted" => true}} =
               Tools.DeleteDocumentTool.execute(params, @frame) |> reply()

      assert {:error, "No document at concepts/kanban.md in wiki"} =
               Tools.DeleteDocumentTool.execute(params, @frame) |> reply()
    end
  end

  describe "link tools" do
    setup do
      Documents.upsert(
        "wiki",
        "concepts/links.md",
        "# Links\n\nSee [[scrum]], [[kanban]] and [[ghost]].\n"
      )

      Oban.drain_queue(queue: :sync)
      :ok
    end

    test "BacklinksTool finds pages linking to a key or a slug" do
      assert {:ok,
              %{"slug" => "scrum", "count" => 1, "backlinks" => [%{"key" => "concepts/links.md"}]}} =
               Tools.BacklinksTool.execute(
                 %{collection: "wiki", key: "concepts/scrum.md"},
                 @frame
               )
               |> reply()

      assert {:ok, %{"count" => 1}} =
               Tools.BacklinksTool.execute(%{collection: "wiki", slug: "ghost"}, @frame)
               |> reply()

      assert {:error, "Pass key or slug"} =
               Tools.BacklinksTool.execute(%{collection: "wiki"}, @frame) |> reply()
    end

    test "OutlinksTool resolves each link" do
      assert {:ok, %{"outlinks" => outlinks}} =
               Tools.OutlinksTool.execute(%{collection: "wiki", key: "concepts/links.md"}, @frame)
               |> reply()

      assert Enum.map(outlinks, &{&1["target"], &1["status"]}) == [
               {"scrum", "ok"},
               {"kanban", "ok"},
               {"ghost", "broken"}
             ]
    end

    test "LinkReportTool reports broken links and orphans" do
      assert {:ok, %{"counts" => %{"broken" => 1}, "broken" => [%{"target" => "ghost"}]}} =
               Tools.LinkReportTool.execute(%{collection: "wiki"}, @frame) |> reply()
    end
  end

  describe "CollectionStatusTool" do
    test "reports one collection, or lists them all" do
      assert {:ok, %{"collection" => "wiki", "documents" => 3, "pending" => 0}} =
               Tools.CollectionStatusTool.execute(%{collection: "wiki"}, @frame) |> reply()

      assert {:ok, %{"collections" => [%{"name" => "wiki", "documents" => 3}]}} =
               Tools.CollectionStatusTool.execute(%{}, @frame) |> reply()
    end
  end
end

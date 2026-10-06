defmodule KB.API.CollectionsTest do
  use KB.DataCase, async: false
  use Oban.Testing, repo: KB.Repo

  import Plug.Test
  import Plug.Conn

  alias KB.Documents
  alias KB.Router

  @opts Router.init([])

  defp request(method, path, body \\ nil) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    conn = Router.call(conn, @opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp run_jobs, do: Oban.drain_queue(queue: :sync)

  defp manifest(docs) do
    Enum.map(docs, fn {key, text} -> %{key: key, content_hash: Documents.hash(text)} end)
  end

  describe "POST /api/ingest/text with a key" do
    test "upserts a keyed document" do
      body = %{text: "# Page\n", collection: "wiki", key: "concepts/page.md", tags: ["t"]}

      assert {202, created} = request(:post, "/api/ingest/text", body)
      assert created["result"] == "created"
      assert created["collection"] == "wiki"
      assert created["key"] == "concepts/page.md"
      assert created["title"] == "Page"
      assert created["tags"] == ["t"]
      assert created["content_hash"] == Documents.hash("# Page\n")

      run_jobs()

      assert {200, again} = request(:post, "/api/ingest/text", body)
      assert again["result"] == "unchanged"
      assert again["id"] == created["id"]
    end

    test "requires a collection with a key" do
      assert {400, %{"error" => "collection is required with key"}} =
               request(:post, "/api/ingest/text", %{text: "x", key: "a.md"})
    end

    test "still dedups unkeyed text into the library" do
      assert {202, first} = request(:post, "/api/ingest/text", %{text: "plain words"})
      assert {200, second} = request(:post, "/api/ingest/text", %{text: "plain words"})
      assert first["id"] == second["id"]
      assert KB.Sources.get_source!(first["id"]).collection == "library"
    end
  end

  describe "POST /api/collections/:c/documents" do
    test "upserts a batch and reports each result" do
      body = %{
        documents: [
          %{key: "a.md", content: "# A\n"},
          %{key: "/bad.md", content: "# Bad\n"},
          %{key: "b.md"}
        ]
      }

      assert {200, resp} = request(:post, "/api/collections/wiki/documents", body)
      assert [a, bad, missing] = resp["results"]
      assert a["result"] == "created"
      assert a["status"] == "pending"
      assert bad["error"] == "key must be a relative path"
      assert missing["error"] == "each document needs a key and content"
      assert resp["counts"] == %{"created" => 1, "error" => 2}
      assert resp["errors"] == 2
    end

    test "reports indexing results when asked to wait" do
      request(:post, "/api/collections/wiki/documents", %{
        documents: [%{key: "a.md", content: "# A\n"}]
      })

      # The test queue does not run on its own, so index before waiting.
      run_jobs()

      assert {200, resp} =
               request(:post, "/api/collections/wiki/documents", %{
                 documents: [%{key: "a.md", content: "# A\n"}],
                 wait: true,
                 timeout: 1
               })

      assert [%{"result" => "unchanged", "status" => "completed", "chunk_count" => 1}] =
               resp["results"]
    end

    test "rejects a bad request" do
      assert {400, _} = request(:post, "/api/collections/wiki/documents", %{documents: []})
      assert {400, _} = request(:post, "/api/collections/Bad!/documents", %{documents: [%{}]})
    end
  end

  describe "POST /api/collections/:c/diff" do
    setup do
      request(:post, "/api/collections/wiki/documents", %{
        documents: [%{key: "keep.md", content: "# Keep\n"}, %{key: "old.md", content: "# Old\n"}]
      })

      run_jobs()
      :ok
    end

    test "returns what to upload, what is extra, and what can be renamed" do
      body = %{manifest: manifest([{"keep.md", "# Keep\n"}, {"new.md", "# Old\n"}])}

      assert {200, diff} = request(:post, "/api/collections/wiki/diff", body)
      assert diff["missing"] == ["new.md"]
      assert diff["extra"] == ["old.md"]
      assert diff["renames"] == [%{"from" => "old.md", "to" => "new.md"}]
      assert diff["unchanged"] == 1
    end

    test "prunes extra keys" do
      body = %{manifest: manifest([{"keep.md", "# Keep\n"}]), prune: true}
      assert {200, %{"pruned" => ["old.md"]}} = request(:post, "/api/collections/wiki/diff", body)
    end

    test "refuses a large prune without force" do
      for i <- 1..8, do: Documents.upsert("wiki", "n#{i}.md", "# #{i}\n")

      assert {409, %{"error" => error}} =
               request(:post, "/api/collections/wiki/diff", %{manifest: [], prune: true})

      assert error =~ "prune would delete 10 of 10 documents"
    end

    test "rejects a bad manifest" do
      assert {400, %{"error" => "manifest must be a list"}} =
               request(:post, "/api/collections/wiki/diff", %{})
    end
  end

  describe "reading documents" do
    setup do
      text = "---\ntype: concept\n---\n# Page\n\n## Details\n\nBody.\n"
      Documents.upsert("wiki", "concepts/page.md", text)
      Documents.upsert("wiki", "entities/thing.md", "# Thing\n")
      run_jobs()
      %{text: text}
    end

    test "GET returns the stored text byte for byte", %{text: text} do
      assert {200, doc} = request(:get, "/api/collections/wiki/documents?key=concepts/page.md")
      assert doc["content"] == text
      assert doc["content_hash"] == Documents.hash(text)
      assert doc["pending"] == false
      assert doc["frontmatter"] == %{"type" => "concept"}
      assert doc["collection"] == "wiki"
    end

    test "GET returns one section", %{text: _text} do
      assert {200, doc} =
               request(
                 :get,
                 "/api/collections/wiki/documents?key=concepts/page.md&section=Details"
               )

      assert doc["content"] == "## Details\n\nBody.\n"
    end

    test "GET reports missing documents and sections" do
      assert {404, _} = request(:get, "/api/collections/wiki/documents?key=nope.md")

      assert {404, _} =
               request(:get, "/api/collections/wiki/documents?key=concepts/page.md&section=Nope")

      assert {400, _} = request(:get, "/api/collections/wiki/documents")
    end

    test "GET reports a document that is not indexed yet" do
      Documents.upsert("wiki", "new.md", "# New\n")

      assert {409, %{"error" => error}} =
               request(:get, "/api/collections/wiki/documents?key=new.md")

      assert error =~ "not been indexed"
    end

    test "POST documents/get reads by prefix or keys" do
      assert {200, %{"documents" => [doc], "truncated" => false}} =
               request(:post, "/api/collections/wiki/documents/get", %{prefix: "concepts/"})

      assert doc["key"] == "concepts/page.md"
      assert doc["content"] =~ "# Page"

      assert {200, %{"documents" => [doc], "missing" => ["x.md"]}} =
               request(:post, "/api/collections/wiki/documents/get", %{
                 keys: ["entities/thing.md", "x.md"],
                 include_content: false
               })

      refute Map.has_key?(doc, "content")
    end
  end

  describe "DELETE /api/collections/:c and reindex" do
    test "drops an empty collection and refuses one with documents" do
      Documents.upsert("wiki", "a.md", "# A\n")
      run_jobs()
      request(:post, "/api/collections/wiki/diff", %{manifest: manifest([{"a.md", "# A\n"}])})

      assert {409, _} = request(:delete, "/api/collections/wiki")
      request(:post, "/api/collections/wiki/delete", %{keys: ["a.md"]})
      assert {200, %{"dropped" => "wiki"}} = request(:delete, "/api/collections/wiki")
      assert {404, _} = request(:delete, "/api/collections/wiki")
    end

    test "queues a reindex" do
      Documents.upsert("wiki", "a.md", "# A\n")
      run_jobs()
      assert {202, %{"queued" => 1}} = request(:post, "/api/collections/wiki/reindex")
    end
  end

  describe "links, contexts and related sources" do
    setup do
      Documents.upsert("wiki", "concepts/debt.md", "# Debt\n\nSee [[memory]] and [[nowhere]].\n")
      Documents.upsert("wiki", "concepts/memory.md", "# Memory\n\nBack to [[debt]].\n")
      run_jobs()
      :ok
    end

    test "GET links by key or slug" do
      assert {200, body} = request(:get, "/api/collections/wiki/links?key=concepts/memory.md")
      assert body["slug"] == "memory"
      assert [%{"key" => "concepts/debt.md", "count" => 1}] = body["backlinks"]
      assert [%{"target" => "debt", "status" => "ok"}] = body["outlinks"]

      assert {200, %{"document" => nil, "backlinks" => [%{"key" => "concepts/debt.md"}]}} =
               request(:get, "/api/collections/wiki/links?slug=nowhere")

      assert {404, _} = request(:get, "/api/collections/wiki/links?key=nope.md")
      assert {400, _} = request(:get, "/api/collections/wiki/links")
    end

    test "GET link_report and POST relink" do
      assert {200, report} = request(:get, "/api/collections/wiki/link_report")

      assert report["broken"] == [
               %{"key" => "concepts/debt.md", "target" => "nowhere", "count" => 1}
             ]

      assert report["orphans"] == []
      assert {200, %{"relinked" => 2}} = request(:post, "/api/collections/wiki/relink")
    end

    test "PUT and GET contexts" do
      assert {200, _} =
               request(:put, "/api/collections/wiki/contexts", %{
                 prefix: "concepts/",
                 description: "One page per idea"
               })

      assert {200,
              %{"contexts" => [%{"prefix" => "concepts/", "description" => "One page per idea"}]}} =
               request(:get, "/api/collections/wiki/contexts")

      assert {200, doc} = request(:get, "/api/collections/wiki/documents?key=concepts/debt.md")
      assert doc["context"] == ["One page per idea"]

      assert {400, _} =
               request(:put, "/api/collections/wiki/contexts", %{prefix: "/x", description: "y"})
    end

    test "GET related sources, limited to a collection" do
      Documents.upsert("library", "papers/debt.txt", "Debt and memory notes.",
        source_type: "text"
      )

      run_jobs()
      {:ok, source} = Documents.get("wiki", "concepts/debt.md")

      assert {200, %{"related" => related}} =
               request(:get, "/api/sources/#{source.id}/related?collection=library")

      assert Enum.all?(related, &(&1["collection"] == "library"))
      assert related != []
      assert {404, _} = request(:get, "/api/sources/#{Ecto.UUID.generate()}/related")
    end
  end

  describe "empty documents" do
    test "an empty text upserts through /api/ingest/text" do
      assert {202, %{"result" => "created"}} =
               request(:post, "/api/ingest/text", %{text: "", collection: "wiki", key: "empty.md"})
    end
  end

  describe "delete, rename and status" do
    setup do
      Documents.upsert("wiki", "a.md", "# A\n")
      run_jobs()
      :ok
    end

    test "POST delete removes documents" do
      assert {200, %{"deleted" => ["a.md"], "not_found" => ["b.md"]}} =
               request(:post, "/api/collections/wiki/delete", %{keys: ["a.md", "b.md"]})
    end

    test "POST rename moves a key" do
      assert {200, %{"key" => "moved/a.md"}} =
               request(:post, "/api/collections/wiki/rename", %{from: "a.md", to: "moved/a.md"})

      assert {404, _} =
               request(:post, "/api/collections/wiki/rename", %{from: "a.md", to: "b.md"})
    end

    test "GET status and the collection list" do
      assert {200, status} = request(:get, "/api/collections/wiki")
      assert status["documents"] == 1
      assert status["chunks"] == 1

      assert {200, %{"collections" => [%{"name" => "wiki", "documents" => 1}]}} =
               request(:get, "/api/collections")
    end
  end

  describe "POST /api/search with the new options" do
    setup do
      Documents.upsert(
        "wiki",
        "concepts/trifecta.md",
        "---\ntype: concept\n---\n# Prompt injection\n\nThe lethal trifecta.\n"
      )

      run_jobs()
      :ok
    end

    test "groups by document and reports how the search went" do
      assert {200, body} =
               request(:post, "/api/search", %{
                 query: ~s("lethal trifecta"),
                 mode: "keyword",
                 group_by: "document",
                 frontmatter: %{type: "concept"}
               })

      assert body["mode"] == "keyword"
      assert body["group_by"] == "document"
      assert body["total"] == 1
      assert body["embedding_used"] == false
      assert body["degraded"] == []
      assert %{"sql_ms" => _, "total_ms" => _, "embed_ms" => nil} = body["timings"]

      assert [
               %{
                 "key" => "concepts/trifecta.md",
                 "collection" => "wiki",
                 "title" => "Prompt injection",
                 "heading_path" => ["Prompt injection"],
                 "snippet" => snippet,
                 "frontmatter" => %{"type" => "concept"}
               }
             ] = body["results"]

      assert snippet =~ "<mark>lethal</mark> <mark>trifecta</mark>"
    end

    test "rejects a bad option" do
      assert {400, %{"error" => "group_by must be" <> _}} =
               request(:post, "/api/search", %{query: "x", group_by: "page"})
    end
  end

  describe "POST /api/search with a collection" do
    test "only returns chunks from that collection" do
      Documents.upsert("wiki", "a.md", "# Alpha\n\nshared words here\n")
      request(:post, "/api/ingest/text", %{text: "shared words here too"})
      run_jobs()
      Oban.drain_queue(queue: :ingestion)

      assert {200, %{"results" => results}} =
               request(:post, "/api/search", %{
                 query: "shared words",
                 mode: "fulltext",
                 collection: "wiki"
               })

      assert [%{"source" => %{"collection" => "wiki", "key" => "a.md"}}] = results

      assert {200, %{"results" => all}} =
               request(:post, "/api/search", %{query: "shared words", mode: "fulltext"})

      assert length(all) == 2
    end
  end
end

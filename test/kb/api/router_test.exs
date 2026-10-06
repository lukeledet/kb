defmodule KB.API.RouterTest do
  use KB.DataCase
  import Plug.Test
  import Plug.Conn

  alias KB.Router
  alias KB.Sources

  @opts Router.init([])

  describe "POST /api/ingest/text" do
    test "returns 202 with source for valid text" do
      conn =
        conn(
          :post,
          "/api/ingest/text",
          Jason.encode!(%{
            text: "This is test content for ingestion.",
            title: "Test Document",
            tags: ["test"],
            source_type: "text"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["id"]
      assert body["status"] == "pending"
      assert body["title"] == "Test Document"
      assert body["tags"] == ["test"]
    end

    test "returns 200 with existing source on dedup" do
      text = "Duplicate content for testing dedup."

      conn1 =
        conn(:post, "/api/ingest/text", Jason.encode!(%{text: text, title: "First"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn1.status == 202
      first_id = Jason.decode!(conn1.resp_body)["id"]

      conn2 =
        conn(:post, "/api/ingest/text", Jason.encode!(%{text: text, title: "Second"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn2.status == 200
      assert Jason.decode!(conn2.resp_body)["id"] == first_id
    end

    test "returns 400 when text is missing" do
      conn =
        conn(:post, "/api/ingest/text", Jason.encode!(%{title: "No text"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "text field is required"
    end

    test "returns 400 for invalid source_type" do
      conn =
        conn(:post, "/api/ingest/text", Jason.encode!(%{text: "content", source_type: "video"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "Invalid source_type"
    end

    test "accepts transcript source_type" do
      conn =
        conn(
          :post,
          "/api/ingest/text",
          Jason.encode!(%{
            text: "Transcript of episode 42.",
            title: "Episode 42",
            source_type: "transcript"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["source_type"] == "transcript"
    end
  end

  describe "POST /api/ingest/file" do
    test "returns 202 for epub upload" do
      epub_content = create_test_epub()

      upload = %Plug.Upload{
        path: write_temp_file(epub_content, ".epub"),
        filename: "test_book.epub",
        content_type: "application/epub+zip"
      }

      conn =
        conn(:post, "/api/ingest/file", %{
          "file" => upload,
          "title" => "Test Book",
          "tags" => "books,test"
        })
        |> Router.call(@opts)

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["id"]
      assert body["status"] == "pending"
      assert body["source_type"] == "epub"
      assert body["tags"] == ["books", "test"]

      cleanup_temp(upload.path)
    end

    test "returns 400 for unsupported file type" do
      upload = %Plug.Upload{
        path: write_temp_file("hello", ".doc"),
        filename: "doc.doc",
        content_type: "application/msword"
      }

      conn =
        conn(:post, "/api/ingest/file", %{"file" => upload})
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "Unsupported file type"

      cleanup_temp(upload.path)
    end

    test "returns 400 when file is missing" do
      conn =
        conn(:post, "/api/ingest/file", %{})
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "file field is required"
    end

    test "returns 200 on dedup for same content" do
      content = "PDF-like content for dedup test"

      upload1 = %Plug.Upload{
        path: write_temp_file(content, ".pdf"),
        filename: "book.pdf",
        content_type: "application/pdf"
      }

      conn1 =
        conn(:post, "/api/ingest/file", %{"file" => upload1})
        |> Router.call(@opts)

      assert conn1.status == 202
      first_id = Jason.decode!(conn1.resp_body)["id"]

      upload2 = %Plug.Upload{
        path: write_temp_file(content, ".pdf"),
        filename: "book_copy.pdf",
        content_type: "application/pdf"
      }

      conn2 =
        conn(:post, "/api/ingest/file", %{"file" => upload2})
        |> Router.call(@opts)

      assert conn2.status == 200
      assert Jason.decode!(conn2.resp_body)["id"] == first_id

      cleanup_temp(upload1.path)
      cleanup_temp(upload2.path)
    end
  end

  describe "POST /api/ingest/url" do
    test "returns 202 with source for a valid url" do
      conn =
        conn(
          :post,
          "/api/ingest/url",
          Jason.encode!(%{
            url: "https://example.com/article",
            title: "Example Article",
            tags: ["web", "test"]
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 202
      body = Jason.decode!(conn.resp_body)
      assert body["id"]
      assert body["status"] == "pending"
      assert body["source_type"] == "url"
      assert body["title"] == "Example Article"
      assert body["tags"] == ["web", "test"]
    end

    test "defaults the title to the url" do
      conn =
        conn(:post, "/api/ingest/url", Jason.encode!(%{url: "https://example.com/no-title"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 202
      assert Jason.decode!(conn.resp_body)["title"] == "https://example.com/no-title"
    end

    test "accepts comma-separated tags" do
      conn =
        conn(
          :post,
          "/api/ingest/url",
          Jason.encode!(%{
            url: "https://example.com/csv-tags",
            tags: "web, elixir"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 202
      assert Jason.decode!(conn.resp_body)["tags"] == ["web", "elixir"]
    end

    test "returns 200 with existing source on dedup" do
      url = "https://example.com/duplicate"

      conn1 =
        conn(:post, "/api/ingest/url", Jason.encode!(%{url: url, title: "First"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn1.status == 202
      first_id = Jason.decode!(conn1.resp_body)["id"]

      conn2 =
        conn(:post, "/api/ingest/url", Jason.encode!(%{url: url, title: "Second"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn2.status == 200
      assert Jason.decode!(conn2.resp_body)["id"] == first_id
    end

    test "re-ingests a duplicate when force is true" do
      url = "https://example.com/forced"

      conn1 =
        conn(:post, "/api/ingest/url", Jason.encode!(%{url: url}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      first_id = Jason.decode!(conn1.resp_body)["id"]

      conn2 =
        conn(:post, "/api/ingest/url", Jason.encode!(%{url: url, force: true}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn2.status == 202
      second_id = Jason.decode!(conn2.resp_body)["id"]
      refute second_id == first_id
      assert Sources.get_source(first_id) == nil
    end

    test "returns 400 when url is missing" do
      conn =
        conn(:post, "/api/ingest/url", Jason.encode!(%{title: "No url"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "url field is required"
    end

    test "returns 400 for a url without an http(s) scheme" do
      conn =
        conn(:post, "/api/ingest/url", Jason.encode!(%{url: "ftp://example.com/file"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "Invalid URL"
    end
  end

  describe "POST /api/search" do
    defp create_searchable_source(attrs) do
      {:ok, source} = Sources.create_source(attrs)

      {:ok, doc} =
        Arcana.ingest("Elixir is a dynamic functional language for building scalable systems.",
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

    test "returns results enriched with source info" do
      create_searchable_source(%{title: "Elixir Guide", source_type: "text", tags: ["elixir"]})

      conn =
        conn(:post, "/api/search", Jason.encode!(%{query: "functional language"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["query"] == "functional language"
      assert body["mode"] == "hybrid"
      assert is_list(body["results"])
      assert body["total"] == length(body["results"])

      if body["total"] > 0 do
        result = hd(body["results"])
        assert result["chunk_id"]
        assert result["text"]
        assert result["source"]["title"] == "Elixir Guide"
        assert result["source"]["tags"] == ["elixir"]
      end
    end

    test "honors mode and tag filter" do
      create_searchable_source(%{title: "Tagged", source_type: "text", tags: ["special"]})
      create_searchable_source(%{title: "Other", source_type: "text", tags: ["other"]})

      conn =
        conn(
          :post,
          "/api/search",
          Jason.encode!(%{query: "language", tags: ["special"], mode: "semantic"})
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["mode"] == "semantic"

      Enum.each(body["results"], fn r ->
        assert "special" in r["source"]["tags"]
      end)
    end

    test "returns 400 when query is missing" do
      conn =
        conn(:post, "/api/search", Jason.encode!(%{tags: ["x"]}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "query field is required"
    end
  end

  describe "GET /api/stats" do
    test "returns aggregate statistics" do
      {:ok, _} = Sources.create_source(%{title: "A", source_type: "url", status: "completed"})
      {:ok, _} = Sources.create_source(%{title: "B", source_type: "text", status: "pending"})

      conn =
        conn(:get, "/api/stats")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["total_sources"] == 2
      assert body["sources_by_status"]["completed"] == 1
      assert body["sources_by_status"]["pending"] == 1
      assert body["sources_by_type"]["url"] == 1
      assert body["sources_by_type"]["text"] == 1
      assert is_integer(body["total_chunks"])
      assert body["content_size"]
      assert body["storage_size"]
    end
  end

  describe "GET /api/sources/:id" do
    test "returns source status" do
      {:ok, source} =
        Sources.create_source(%{title: "Test", source_type: "text", status: "pending"})

      conn =
        conn(:get, "/api/sources/#{source.id}")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == source.id
      assert body["status"] == "pending"
    end

    test "returns 404 for missing source" do
      conn =
        conn(:get, "/api/sources/#{Ecto.UUID.generate()}")
        |> Router.call(@opts)

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "Source not found"
    end
  end

  describe "GET /api/sources/:id/content" do
    test "returns the full ingested text" do
      text = "Elixir is a dynamic functional language for building scalable systems."
      {:ok, source} = Sources.create_source(%{title: "Elixir Guide", source_type: "text"})

      {:ok, doc} =
        Arcana.ingest(text, repo: KB.Repo, source_id: source.id, collection: "kb")

      {:ok, source} =
        Sources.update_source(source, %{
          status: "completed",
          arcana_document_id: doc.id,
          chunk_count: doc.chunk_count
        })

      conn =
        conn(:get, "/api/sources/#{source.id}/content")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == source.id
      assert body["title"] == "Elixir Guide"
      assert body["content"] == text
      assert body["chunk_count"] == doc.chunk_count
    end

    test "returns 409 for a source that has not been ingested yet" do
      {:ok, source} =
        Sources.create_source(%{title: "Pending", source_type: "text", status: "pending"})

      conn =
        conn(:get, "/api/sources/#{source.id}/content")
        |> Router.call(@opts)

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] =~ "no content"
    end

    test "returns 404 for missing source" do
      conn =
        conn(:get, "/api/sources/#{Ecto.UUID.generate()}/content")
        |> Router.call(@opts)

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "Source not found"
    end
  end

  describe "PATCH /api/sources/:id" do
    test "updates the title" do
      {:ok, source} =
        Sources.create_source(%{title: "Old Title", source_type: "text", status: "completed"})

      conn =
        conn(:patch, "/api/sources/#{source.id}", Jason.encode!(%{title: "New Title"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == source.id
      assert body["title"] == "New Title"
      assert Sources.get_source!(source.id).title == "New Title"
    end

    test "trims surrounding whitespace" do
      {:ok, source} =
        Sources.create_source(%{title: "Old Title", source_type: "text", status: "completed"})

      conn =
        conn(:patch, "/api/sources/#{source.id}", Jason.encode!(%{title: "  Padded  "}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["title"] == "Padded"
    end

    test "merges metadata into what is already stored" do
      {:ok, source} =
        Sources.create_source(%{
          title: "Old Title",
          source_type: "text",
          status: "completed",
          metadata: %{"author" => "Someone"}
        })

      conn =
        conn(
          :patch,
          "/api/sources/#{source.id}",
          Jason.encode!(%{metadata: %{"hn" => "https://news.ycombinator.com/item?id=1"}})
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body)["metadata"] == %{
               "author" => "Someone",
               "hn" => "https://news.ycombinator.com/item?id=1"
             }

      assert Sources.get_source!(source.id).metadata["author"] == "Someone"
    end

    test "drops metadata keys sent as null" do
      {:ok, source} =
        Sources.create_source(%{
          title: "Old Title",
          source_type: "text",
          status: "completed",
          metadata: %{"author" => "Someone", "hn" => "https://example.com"}
        })

      conn =
        conn(:patch, "/api/sources/#{source.id}", Jason.encode!(%{metadata: %{"hn" => nil}}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["metadata"] == %{"author" => "Someone"}
    end

    test "updates title and metadata together" do
      {:ok, source} =
        Sources.create_source(%{title: "Old Title", source_type: "text", status: "completed"})

      conn =
        conn(
          :patch,
          "/api/sources/#{source.id}",
          Jason.encode!(%{title: "New Title", metadata: %{"hn" => "https://example.com"}})
        )
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["title"] == "New Title"
      assert body["metadata"] == %{"hn" => "https://example.com"}
    end

    test "returns 400 when metadata is not an object" do
      {:ok, source} =
        Sources.create_source(%{title: "Old Title", source_type: "text", status: "completed"})

      conn =
        conn(:patch, "/api/sources/#{source.id}", Jason.encode!(%{metadata: "nope"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "metadata must be a JSON object"
    end

    test "returns 400 when title is blank" do
      {:ok, source} =
        Sources.create_source(%{title: "Old Title", source_type: "text", status: "completed"})

      for body <- [%{title: ""}, %{title: "   "}] do
        conn =
          conn(:patch, "/api/sources/#{source.id}", Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
          |> Router.call(@opts)

        assert conn.status == 400
        assert Jason.decode!(conn.resp_body)["error"] =~ "title field is required"
      end
    end

    test "returns 400 when neither title nor metadata is given" do
      {:ok, source} =
        Sources.create_source(%{title: "Old Title", source_type: "text", status: "completed"})

      conn =
        conn(:patch, "/api/sources/#{source.id}", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "title or metadata field is required"
    end

    test "returns 404 for missing source" do
      conn =
        conn(:patch, "/api/sources/#{Ecto.UUID.generate()}", Jason.encode!(%{title: "X"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] == "Source not found"
    end

    test "returns 404 for invalid UUID" do
      conn =
        conn(:patch, "/api/sources/not-a-uuid", Jason.encode!(%{title: "X"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@opts)

      assert conn.status == 404
    end
  end

  defp write_temp_file(content, ext) do
    path = Path.join(System.tmp_dir!(), "kb_test_#{System.unique_integer([:positive])}#{ext}")
    File.write!(path, content)
    path
  end

  defp cleanup_temp(path), do: File.rm(path)

  defp create_test_epub do
    container_xml =
      ~s(<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>)

    content_opf =
      ~s(<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Test</dc:title></metadata><manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="ch1"/></spine></package>)

    ch1 = ~s(<html><body><p>Chapter one content.</p></body></html>)

    files = [
      {~c"META-INF/container.xml", container_xml},
      {~c"OEBPS/content.opf", content_opf},
      {~c"OEBPS/ch1.xhtml", ch1}
    ]

    tmp = Path.join(System.tmp_dir!(), "test_epub_#{System.unique_integer([:positive])}.epub")
    {:ok, _} = :zip.create(String.to_charlist(tmp), files)
    content = File.read!(tmp)
    File.rm(tmp)
    content
  end
end

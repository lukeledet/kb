defmodule KB.ErrorPathsTest do
  use KB.DataCase
  import Plug.Test
  import Plug.Conn

  alias KB.Router
  alias KB.Sources
  alias KB.Workers.{IngestUrl, IngestContent}

  @router_opts Router.init([])
  @frame Anubis.Server.Frame.new()

  describe "Oban job failure → source status :failed" do
    test "IngestUrl marks source as failed on HTTP error" do
      {:ok, source} =
        Sources.create_source(%{
          title: "Bad URL",
          source_type: "url",
          url: "https://example.com/500"
        })

      Req.Test.stub(IngestUrl, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      Application.put_env(:kb, :req_options, plug: {Req.Test, IngestUrl}, retry: false)
      on_exit(fn -> Application.delete_env(:kb, :req_options) end)

      job = %Oban.Job{args: %{"source_id" => source.id}}
      assert {:error, {:http_error, 500}} = IngestUrl.perform(job)

      updated = Sources.get_source!(source.id)
      assert updated.status == "failed"
      assert updated.error =~ "http_error"
    end

    test "IngestContent marks source as failed on missing temp file" do
      {:ok, source} =
        Sources.create_source(%{title: "Missing", source_type: "text"})

      job = %Oban.Job{args: %{"source_id" => source.id, "temp_path" => "/nonexistent/path"}}
      assert {:error, :temp_file_missing} = IngestContent.perform(job)

      updated = Sources.get_source!(source.id)
      assert updated.status == "failed"
      assert updated.error =~ "temp_file_missing"
    end
  end

  defmodule RaisingEmbedder do
    @behaviour Arcana.Embedder
    def embed(_text, _opts \\ []), do: raise("embedder exploded")
    def embed_batch(_texts, _opts \\ []), do: raise("embedder exploded")
    def dimensions(_opts \\ []), do: 4096
  end

  describe "a raise inside an ingest worker" do
    setup do
      prev = Application.get_env(:arcana, :embedder)
      Application.put_env(:arcana, :embedder, RaisingEmbedder)
      on_exit(fn -> Application.put_env(:arcana, :embedder, prev) end)
    end

    test "IngestContent marks the source failed and re-raises" do
      {:ok, source} = Sources.create_source(%{title: "Crash", source_type: "text"})
      temp_path = write_temp("Some text to ingest.", ".bin")
      on_exit(fn -> cleanup(temp_path) end)

      job = %Oban.Job{args: %{"source_id" => source.id, "temp_path" => temp_path}}
      assert_raise RuntimeError, "embedder exploded", fn -> IngestContent.perform(job) end

      updated = Sources.get_source!(source.id)
      assert updated.status == "failed"
      assert updated.error == "embedder exploded"
      # The retry needs the file.
      assert File.exists?(temp_path)
    end

    test "IngestContent marks a retry failed again, not left processing" do
      {:ok, source} =
        Sources.create_source(%{
          title: "Crash",
          source_type: "text",
          status: "failed",
          error: "embedder exploded"
        })

      temp_path = write_temp("Some text to ingest.", ".bin")
      on_exit(fn -> cleanup(temp_path) end)

      job = %Oban.Job{args: %{"source_id" => source.id, "temp_path" => temp_path}}
      assert_raise RuntimeError, fn -> IngestContent.perform(job) end

      assert Sources.get_source!(source.id).status == "failed"
    end

    test "IngestUrl marks the source failed and re-raises" do
      Req.Test.stub(IngestUrl, fn conn ->
        Req.Test.html(conn, "<html><body><article><p>Some page text.</p></article></body></html>")
      end)

      Application.put_env(:kb, :req_options, plug: {Req.Test, IngestUrl}, retry: false)
      on_exit(fn -> Application.delete_env(:kb, :req_options) end)

      url = "https://example.com/crash"
      {:ok, source} = Sources.create_source(%{title: url, source_type: "url", url: url})

      job = %Oban.Job{args: %{"source_id" => source.id}}
      assert_raise RuntimeError, "embedder exploded", fn -> IngestUrl.perform(job) end

      updated = Sources.get_source!(source.id)
      assert updated.status == "failed"
      assert updated.error == "embedder exploded"
    end
  end

  describe "HTTP API error paths" do
    test "POST /api/ingest/text with empty text string returns 400" do
      conn =
        conn(:post, "/api/ingest/text", Jason.encode!(%{text: "", title: "Empty"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@router_opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "text field is required"
    end

    test "POST /api/ingest/text with no body returns 400" do
      conn =
        conn(:post, "/api/ingest/text", Jason.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@router_opts)

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "text field is required"
    end

    test "POST /api/ingest/file with .txt extension returns 400" do
      upload = %Plug.Upload{
        path: write_temp("hello", ".txt"),
        filename: "readme.txt",
        content_type: "text/plain"
      }

      conn =
        conn(:post, "/api/ingest/file", %{"file" => upload})
        |> Router.call(@router_opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "Unsupported file type: .txt"
      assert body["error"] =~ ".pdf, .epub"

      cleanup(upload.path)
    end

    test "POST /api/ingest/file force re-ingest deletes existing and creates new" do
      content = "force-reupload-content"
      hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      {:ok, existing} =
        Sources.create_source(%{
          title: "Old Version",
          source_type: "pdf",
          content_hash: hash
        })

      upload = %Plug.Upload{
        path: write_temp(content, ".pdf"),
        filename: "book.pdf",
        content_type: "application/pdf"
      }

      conn =
        conn(:post, "/api/ingest/file", %{"file" => upload, "force" => "true"})
        |> Router.call(@router_opts)

      assert conn.status == 202
      new_id = Jason.decode!(conn.resp_body)["id"]
      assert new_id != existing.id
      assert Sources.get_source(existing.id) == nil

      cleanup(upload.path)
    end

    test "POST /api/ingest/text force re-ingest works" do
      text = "force-reingest-text-content"

      conn1 =
        conn(:post, "/api/ingest/text", Jason.encode!(%{text: text, title: "V1"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@router_opts)

      assert conn1.status == 202
      first_id = Jason.decode!(conn1.resp_body)["id"]

      conn2 =
        conn(:post, "/api/ingest/text", Jason.encode!(%{text: text, title: "V2", force: true}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(@router_opts)

      assert conn2.status == 202
      second_id = Jason.decode!(conn2.resp_body)["id"]
      assert second_id != first_id
      assert Sources.get_source(first_id) == nil
    end

    test "GET /api/sources/:id with invalid UUID returns 404" do
      conn =
        conn(:get, "/api/sources/not-a-uuid")
        |> Router.call(@router_opts)

      assert conn.status == 404
    end

    test "unknown API route returns 404" do
      conn =
        conn(:get, "/api/nonexistent")
        |> Router.call(@router_opts)

      assert conn.status == 404
    end
  end

  describe "MCP error paths" do
    test "SearchTool with empty query still executes" do
      # Empty string queries are allowed (Arcana handles them)
      {:reply, resp, _} =
        KB.MCP.Tools.SearchTool.execute(%{query: "x"}, @frame)

      refute resp.isError
    end

    test "IngestUrlTool rejects URL without scheme" do
      {:reply, resp, _} =
        KB.MCP.Tools.IngestUrlTool.execute(%{url: "example.com"}, @frame)

      assert resp.isError
      [%{"text" => text}] = resp.content
      assert text =~ "must start with http"
    end

    test "IngestUrlTool rejects FTP URL" do
      {:reply, resp, _} =
        KB.MCP.Tools.IngestUrlTool.execute(%{url: "ftp://files.example.com/doc"}, @frame)

      assert resp.isError
    end

    test "GetChunksTool returns empty for source with no arcana document" do
      {:ok, source} = Sources.create_source(%{title: "Pending", source_type: "text"})

      {:reply, resp, _} =
        KB.MCP.Tools.GetChunksTool.execute(%{source_id: source.id}, @frame)

      refute resp.isError
      [%{"text" => json}] = resp.content
      result = Jason.decode!(json)
      assert result["chunks"] == []
      assert result["total"] == 0
    end
  end

  defp write_temp(content, ext) do
    path = Path.join(System.tmp_dir!(), "kb_test_#{System.unique_integer([:positive])}#{ext}")
    File.write!(path, content)
    path
  end

  defp cleanup(path), do: File.rm(path)
end

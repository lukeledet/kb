defmodule KB.Workers.IngestUrlTest do
  use KB.DataCase

  alias KB.Sources
  alias KB.Workers.IngestUrl

  @html """
  <html>
  <head><title>Test Page</title></head>
  <body>
    <article>
      <h1>Test Article</h1>
      <p>This is test content for ingestion. It needs to be long enough to create at least one chunk during the Arcana ingestion process.</p>
    </article>
  </body>
  </html>
  """

  setup do
    Req.Test.stub(IngestUrl, fn conn ->
      Req.Test.html(conn, @html)
    end)

    Application.put_env(:kb, :req_options, plug: {Req.Test, IngestUrl})
    on_exit(fn -> Application.delete_env(:kb, :req_options) end)
    :ok
  end

  describe "perform/1" do
    test "ingests URL and updates source to completed" do
      {:ok, source} =
        Sources.create_source(%{
          title: "Test Page",
          source_type: "url",
          url: "https://example.com/test"
        })

      job = %Oban.Job{args: %{"source_id" => source.id}}

      assert :ok = IngestUrl.perform(job)

      updated = Sources.get_source!(source.id)
      assert updated.status == "completed"
      assert updated.chunk_count > 0
      assert updated.arcana_document_id != nil
      assert updated.content_hash != nil
    end

    test "takes the title from the page when the title is just the URL" do
      url = "https://example.com/test"

      {:ok, source} = Sources.create_source(%{title: url, source_type: "url", url: url})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})

      assert Sources.get_source!(source.id).title == "Test Page"
    end

    test "auto tags a source that has none" do
      Application.put_env(:kb, :fake_tags, ["testing"])
      on_exit(fn -> Application.delete_env(:kb, :fake_tags) end)

      url = "https://example.com/test"
      {:ok, source} = Sources.create_source(%{title: url, source_type: "url", url: url})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})

      assert Sources.get_source!(source.id).tags == ["testing"]
    end

    test "keeps caller-supplied tags" do
      Application.put_env(:kb, :fake_tags, ["testing"])
      on_exit(fn -> Application.delete_env(:kb, :fake_tags) end)

      url = "https://example.com/test"

      {:ok, source} =
        Sources.create_source(%{title: url, source_type: "url", url: url, tags: ["mine"]})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})

      assert Sources.get_source!(source.id).tags == ["mine"]
    end

    test "keeps a caller-supplied title" do
      url = "https://example.com/test"

      {:ok, source} =
        Sources.create_source(%{title: "My Own Title", source_type: "url", url: url})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})

      assert Sources.get_source!(source.id).title == "My Own Title"
    end

    test "keeps the URL stand-in when the page has no title" do
      Req.Test.stub(IngestUrl, fn conn ->
        Req.Test.html(
          conn,
          "<html><body><article><p>#{String.duplicate("Body text. ", 20)}</p></article></body></html>"
        )
      end)

      url = "https://example.com/untitled"

      {:ok, source} = Sources.create_source(%{title: url, source_type: "url", url: url})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})

      assert Sources.get_source!(source.id).title == url
    end

    test "cancels instead of retrying when the source was deleted before it ran" do
      {:ok, source} =
        Sources.create_source(%{
          title: "Gone",
          source_type: "url",
          url: "https://example.com/gone"
        })

      {:ok, _} = Sources.delete_source(source)

      assert {:cancel, :source_deleted} =
               IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})
    end

    test "cancels when the source is deleted mid-flight" do
      url = "https://example.com/racy"
      {:ok, source} = Sources.create_source(%{title: url, source_type: "url", url: url})

      # Drop the row while the worker is mid-request — the same window a
      # --force re-ingest opens between the "processing" update and write-back.
      Req.Test.stub(IngestUrl, fn conn ->
        {:ok, _} = Sources.delete_source(Sources.get_source!(source.id))
        Req.Test.html(conn, @html)
      end)

      assert {:cancel, :source_deleted} =
               IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})
    end

    test "fails without retrying when another source has the same content" do
      {:ok, first} =
        Sources.create_source(%{title: "First", source_type: "url", url: "https://example.com/a"})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => first.id}})

      {:ok, second} =
        Sources.create_source(%{
          title: "Second",
          source_type: "url",
          url: "https://example.com/b"
        })

      assert {:cancel, :duplicate_content} =
               IngestUrl.perform(%Oban.Job{args: %{"source_id" => second.id}})

      updated = Sources.get_source!(second.id)
      assert updated.status == "failed"
      assert updated.error =~ first.id
    end

    test "ingests a PDF served from a URL" do
      Req.Test.stub(IngestUrl, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/pdf")
        |> Plug.Conn.send_resp(200, File.read!("test/fixtures/sample.pdf"))
      end)

      url = "https://example.com/paper.pdf"
      {:ok, source} = Sources.create_source(%{title: "Paper", source_type: "url", url: url})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})

      updated = Sources.get_source!(source.id)
      assert updated.status == "completed"
      assert updated.title == "Paper"
      document = KB.Repo.get!(Arcana.Document, updated.arcana_document_id)
      assert document.content =~ "Sample PDF text for ingestion tests."
    end

    test "detects a PDF by its signature when the server sends a generic type" do
      Req.Test.stub(IngestUrl, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.send_resp(200, File.read!("test/fixtures/sample.pdf"))
      end)

      url = "https://example.com/download"
      {:ok, source} = Sources.create_source(%{title: url, source_type: "url", url: url})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})
      assert Sources.get_source!(source.id).status == "completed"
    end

    test "strips NUL bytes from page text" do
      Req.Test.stub(IngestUrl, fn conn ->
        Req.Test.html(
          conn,
          "<html><body><article><p>Page with a NUL\u0000 byte.</p></article></body></html>"
        )
      end)

      url = "https://example.com/nul"
      {:ok, source} = Sources.create_source(%{title: url, source_type: "url", url: url})

      assert :ok = IngestUrl.perform(%Oban.Job{args: %{"source_id" => source.id}})

      updated = Sources.get_source!(source.id)
      assert updated.status == "completed"
      document = KB.Repo.get!(Arcana.Document, updated.arcana_document_id)
      refute String.contains?(document.content, <<0>>)
    end

    test "sets source to failed on HTTP error" do
      Req.Test.stub(IngestUrl, fn conn ->
        Plug.Conn.send_resp(conn, 404, "Not Found")
      end)

      {:ok, source} =
        Sources.create_source(%{
          title: "Bad URL",
          source_type: "url",
          url: "https://example.com/404"
        })

      job = %Oban.Job{args: %{"source_id" => source.id}}

      assert {:error, {:http_error, 404}} = IngestUrl.perform(job)

      updated = Sources.get_source!(source.id)
      assert updated.status == "failed"
      assert updated.error =~ "http_error"
    end
  end
end

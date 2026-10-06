defmodule KB.Workers.IngestContentTest do
  use KB.DataCase, async: true

  alias KB.Sources
  alias KB.Workers.IngestContent

  describe "perform/1" do
    test "ingests text content and updates source" do
      {:ok, source} =
        Sources.create_source(%{
          title: "Test Text",
          source_type: "text",
          content_hash:
            :crypto.hash(:sha256, "Test content for ingestion.") |> Base.encode16(case: :lower)
        })

      temp_path = IngestContent.temp_path(source.id)
      File.write!(temp_path, "Test content for ingestion.")
      on_exit(fn -> File.rm(temp_path) end)

      job = %Oban.Job{args: %{"source_id" => source.id, "temp_path" => temp_path}}

      assert :ok = IngestContent.perform(job)

      updated = Sources.get_source!(source.id)
      assert updated.status == "completed"
      assert updated.chunk_count > 0
      assert updated.arcana_document_id != nil

      # Temp file should be deleted after success
      refute File.exists?(temp_path)
    end

    test "takes title and author from the epub when the title is just the filename" do
      source = ingest_epub(%{title: "test_book.epub", source_type: "epub"})

      assert source.status == "completed"
      assert source.title == "Test Book"
      assert source.metadata["author"] == "Test Author"
    end

    test "keeps a caller-supplied title but still records the author" do
      source = ingest_epub(%{title: "My Own Title", source_type: "epub"})

      assert source.title == "My Own Title"
      assert source.metadata["author"] == "Test Author"
      assert source.metadata["title"] == "Test Book"
    end

    test "does not overwrite caller-supplied metadata" do
      source =
        ingest_epub(%{
          title: "test_book.epub",
          source_type: "epub",
          metadata: %{"author" => "Someone Else"}
        })

      assert source.metadata["author"] == "Someone Else"
    end

    test "cancels instead of retrying when the source was deleted before it ran" do
      {:ok, source} = Sources.create_source(%{title: "Gone", source_type: "text"})

      temp_path = IngestContent.temp_path(source.id)
      File.write!(temp_path, "Some content that will never be ingested.")
      on_exit(fn -> File.rm(temp_path) end)

      {:ok, _} = Sources.delete_source(source)

      job = %Oban.Job{args: %{"source_id" => source.id, "temp_path" => temp_path}}

      assert {:cancel, :source_deleted} = IngestContent.perform(job)
      refute File.exists?(temp_path)
    end

    test "sets source to failed when temp file is missing" do
      {:ok, source} =
        Sources.create_source(%{
          title: "Missing File",
          source_type: "text"
        })

      temp_path = IngestContent.temp_path(source.id)

      job = %Oban.Job{args: %{"source_id" => source.id, "temp_path" => temp_path}}

      assert {:error, :temp_file_missing} = IngestContent.perform(job)

      updated = Sources.get_source!(source.id)
      assert updated.status == "failed"
      assert updated.error =~ "temp_file_missing"
    end
  end

  defp ingest_epub(attrs) do
    epub = test_epub()
    {:ok, source} = Sources.create_source(Map.put(attrs, :content_hash, hash(epub)))

    temp_path = IngestContent.temp_path(source.id)
    File.write!(temp_path, epub)
    on_exit(fn -> File.rm(temp_path) end)

    assert :ok =
             IngestContent.perform(%Oban.Job{
               args: %{"source_id" => source.id, "temp_path" => temp_path}
             })

    Sources.get_source!(source.id)
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp test_epub do
    container_xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    content_opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Test Book</dc:title>
        <dc:creator>Test Author</dc:creator>
      </metadata>
      <manifest>
        <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="ch1"/>
      </spine>
    </package>
    """

    chapter1 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>Chapter 1</title></head>
    <body>
      <h1>Chapter One</h1>
      <p>This is the first chapter content. It needs to be long enough to create
      at least one chunk during the Arcana ingestion process, so here is some
      more filler prose to push it over the minimum length.</p>
    </body>
    </html>
    """

    path = Path.join(System.tmp_dir!(), "worker_book_#{System.unique_integer([:positive])}.epub")

    {:ok, _} =
      :zip.create(String.to_charlist(path), [
        {~c"META-INF/container.xml", container_xml},
        {~c"OEBPS/content.opf", content_opf},
        {~c"OEBPS/chapter1.xhtml", chapter1}
      ])

    content = File.read!(path)
    File.rm(path)
    content
  end
end

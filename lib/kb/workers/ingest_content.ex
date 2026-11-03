defmodule KB.Workers.IngestContent do
  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias KB.Sources
  alias KB.Parsers.{Epub, Pdf}
  alias KB.Tagger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id, "temp_path" => temp_path}}) do
    case Sources.get_source(source_id) do
      nil ->
        File.rm(temp_path)
        {:cancel, :source_deleted}

      source ->
        run(source, temp_path)
    end
  end

  # A raise, such as a database error inside the insert, would skip the
  # failure handling in ingest/2 and leave the source "processing" for good.
  # Record it, then re-raise so Oban keeps the stacktrace and still retries.
  # The temp file stays for the retry.
  defp run(source, temp_path) do
    ingest(source, temp_path)
  rescue
    exception ->
      Sources.mark_failed(source.id, Exception.message(exception))
      reraise exception, __STACKTRACE__
  end

  defp ingest(source, temp_path) do
    with {:ok, source} <- Sources.update_source_if_present(source, %{status: "processing"}),
         {:ok, content} <- read_temp_file(temp_path),
         {:ok, text, parsed} <- parse_content(content, source.source_type),
         text = KB.Text.sanitize(text),
         {:ok, source} <- apply_parsed_metadata(source, parsed),
         source <- Tagger.maybe_auto_tag(source, text),
         {:ok, document} <- ingest_text(text, source),
         {:ok, _source} <-
           Sources.update_source_if_present(source, %{
             status: "completed",
             arcana_document_id: document.id,
             chunk_count: document.chunk_count,
             error: nil
           }) do
      File.rm(temp_path)
      :ok
    else
      # Deleted mid-flight (a --force re-ingest, or a manual delete). There is
      # nothing left to record the failure against, so cancel rather than burn
      # the retry budget failing the same way five times.
      {:error, :source_deleted} ->
        File.rm(temp_path)
        {:cancel, :source_deleted}

      {:error, reason} ->
        Sources.mark_failed(source.id, inspect(reason))
        {:error, reason}
    end
  end

  defp read_temp_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :temp_file_missing}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  defp parse_content(content, "epub") do
    tmp_epub =
      Path.join(
        System.tmp_dir!(),
        "kb_epub_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}.epub"
      )

    try do
      File.write!(tmp_epub, content)

      case Epub.parse(tmp_epub) do
        {:ok, %{text: text, metadata: metadata}} -> {:ok, text, metadata}
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(tmp_epub)
    end
  end

  defp parse_content(content, "pdf") do
    case Pdf.parse(content) do
      {:ok, text} -> {:ok, text, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_content(content, _type) do
    {:ok, content, %{}}
  end

  # Promote what the parser found in the document itself: its title (only over
  # a stand-in, see KB.Sources.placeholder_title?/1) and its author. Runs
  # before ingest_text/2 so the chunks carry the final values, not the
  # filename we started with.
  defp apply_parsed_metadata(source, parsed) do
    title = clean(parsed[:title])
    author = clean(parsed[:author])

    attrs =
      %{}
      |> put_title(source, title)
      |> put_metadata(source, %{"title" => title, "author" => author})

    if map_size(attrs) == 0,
      do: {:ok, source},
      else: Sources.update_source_if_present(source, attrs)
  end

  defp put_title(attrs, source, title) do
    if title && Sources.placeholder_title?(source) do
      Map.put(attrs, :title, title)
    else
      attrs
    end
  end

  defp put_metadata(attrs, source, discovered) do
    existing = source.metadata || %{}

    # Caller-supplied metadata wins; we only fill gaps.
    merged =
      discovered
      |> Enum.reject(fn {k, v} -> is_nil(v) or Map.has_key?(existing, k) end)
      |> Map.new()

    if map_size(merged) == 0 do
      attrs
    else
      Map.put(attrs, :metadata, Map.merge(existing, merged))
    end
  end

  defp clean(nil), do: nil

  defp clean(value) when is_binary(value) do
    case value |> KB.Text.sanitize() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp ingest_text(text, source) do
    KB.Ingest.ingest(text,
      repo: KB.Repo,
      source_id: source.id,
      metadata: source.metadata || %{},
      collection: "kb"
    )
  end

  def temp_path(source_id) do
    Path.join(System.tmp_dir!(), "kb_ingest_#{source_id}.bin")
  end
end

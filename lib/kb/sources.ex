defmodule KB.Sources do
  import Ecto.Query

  alias KB.Repo
  alias KB.Sources.Source

  def create_source(attrs) do
    %Source{}
    |> Source.changeset(Map.put_new(attrs, :status, "pending"))
    |> Repo.insert()
  end

  def get_source(id) do
    Repo.get(Source, id)
  end

  def get_source!(id) do
    Repo.get!(Source, id)
  end

  def list_sources(opts \\ []) do
    Source
    |> maybe_filter_tags(opts[:tags])
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_collection(opts[:collection])
    |> order_by([s], desc: s.inserted_at)
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> Repo.all()
  end

  def update_source(%Source{} = source, attrs) do
    source
    |> Source.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Like `update_source/2`, but reports a row that has since been deleted as
  `{:error, :source_deleted}` instead of raising `Ecto.StaleEntryError`.

  Ingestion runs for minutes; a `--force` re-ingest or a manual delete can drop
  the row mid-flight. Raising there costs the job its full retry budget, every
  attempt failing the same way, so ingestion workers use this and cancel
  instead.
  """
  def update_source_if_present(%Source{} = source, attrs) do
    source
    |> Source.changeset(attrs)
    |> Repo.update(stale_error_field: :id, stale_error_message: "deleted")
    |> case do
      {:ok, source} -> {:ok, source}
      {:error, %Ecto.Changeset{errors: [{:id, {"deleted", _}} | _]}} -> {:error, :source_deleted}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Sets a source's status to "failed" and records `error`.

  Writes by id rather than through a changeset. An ingest worker holds the
  source as it was loaded, which on a retry is already "failed" with the same
  error. A changeset against that struct sees no change and writes nothing,
  so the row would stay "processing". Does nothing if the source is gone.
  """
  def mark_failed(source_id, error) when is_binary(error) do
    from(s in Source, where: s.id == ^source_id)
    |> Repo.update_all(
      set: [status: "failed", error: error, updated_at: DateTime.utc_now(:second)]
    )

    :ok
  end

  @doc """
  True when a source's title is still the stand-in chosen at creation time —
  the uploaded filename, the URL itself, or "Untitled" — rather than one the
  caller picked.

  Parsers discover better titles (an EPUB's `dc:title`, a page's `<title>`),
  but a caller who passed an explicit title meant it, so ingestion only fills
  in over a stand-in.
  """
  def placeholder_title?(%Source{title: title}) when title in [nil, ""], do: true

  def placeholder_title?(%Source{source_type: "url", title: title, url: url}), do: title == url

  def placeholder_title?(%Source{source_type: type, title: title}) when type in ~w(pdf epub) do
    String.ends_with?(String.downcase(title), "." <> type)
  end

  def placeholder_title?(%Source{title: title}), do: title == "Untitled"

  def delete_source(%Source{} = source) do
    arcana_doc_id = source.arcana_document_id

    # Delete source first (it holds the FK to arcana_documents)
    result = Repo.delete(source)

    # Then clean up the Arcana document and its chunks
    if arcana_doc_id do
      Arcana.delete(arcana_doc_id, repo: Repo)
    end

    result
  end

  def update_tags(%Source{} = source, tags) when is_list(tags) do
    source
    |> Source.changeset(%{tags: tags})
    |> Repo.update()
  end

  def list_tags do
    Source
    |> where([s], fragment("cardinality(?) > 0", s.tags))
    |> select([s], s.tags)
    |> Repo.all()
    |> List.flatten()
    |> Enum.frequencies()
    |> Enum.map(fn {tag, count} -> %{tag: tag, count: count} end)
    |> Enum.sort_by(& &1.tag)
  end

  def count_sources(opts \\ []) do
    Source
    |> maybe_filter_tags(opts[:tags])
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_collection(opts[:collection])
    |> Repo.aggregate(:count)
  end

  @doc """
  Aggregate statistics across the entire knowledge base.

  Returns counts of sources (overall and broken down by status and type),
  chunk totals and averages, the byte size of the indexed text content, and
  the on-disk storage footprint (data + indexes, including embeddings) of the
  KB tables.
  """
  def stats do
    by_status =
      Source
      |> group_by([s], s.status)
      |> select([s], {s.status, count(s.id)})
      |> Repo.all()
      |> Map.new()

    by_type =
      Source
      |> group_by([s], s.source_type)
      |> select([s], {s.source_type, count(s.id)})
      |> Repo.all()
      |> Map.new()

    by_collection =
      Source
      |> group_by([s], s.collection)
      |> select([s], {s.collection, count(s.id)})
      |> Repo.all()
      |> Map.new()

    total_sources = by_status |> Map.values() |> Enum.sum()

    chunked_sources =
      Source
      |> where([s], s.chunk_count > 0)
      |> Repo.aggregate(:count)

    # Ground-truth chunk count and text size from the chunk table itself.
    %{rows: [[chunk_count, content_bytes]]} =
      Repo.query!("SELECT COUNT(*), COALESCE(SUM(octet_length(text)), 0) FROM arcana_chunks")

    # On-disk footprint (data + indexes, including the HNSW embedding index).
    %{rows: [[storage_bytes]]} =
      Repo.query!("""
      SELECT COALESCE(
        pg_total_relation_size('sources') +
        pg_total_relation_size('arcana_documents') +
        pg_total_relation_size('arcana_chunks'), 0)
      """)

    %{rows: [[unique_tags]]} =
      Repo.query!("SELECT COUNT(DISTINCT tag) FROM sources, unnest(tags) AS tag")

    chunk_count = normalize_int(chunk_count)
    content_bytes = normalize_int(content_bytes)
    storage_bytes = normalize_int(storage_bytes)

    avg_chunks =
      if chunked_sources > 0, do: Float.round(chunk_count / chunked_sources, 1), else: 0.0

    %{
      total_sources: total_sources,
      sources_by_status: by_status,
      sources_by_type: by_type,
      sources_by_collection: by_collection,
      total_chunks: chunk_count,
      chunked_sources: chunked_sources,
      avg_chunks_per_source: avg_chunks,
      content_bytes: content_bytes,
      content_size: format_bytes(content_bytes),
      storage_bytes: storage_bytes,
      storage_size: format_bytes(storage_bytes),
      unique_tags: normalize_int(unique_tags)
    }
  end

  @doc """
  The full text of a source, exactly as it was ingested.

  Reads the stored document rather than stitching chunks back together: chunks
  overlap by design, so joining them would repeat text at every boundary.

  Returns `{:error, :no_content}` for a source that has not finished ingesting
  (no document yet) or whose document has since been removed.
  """
  def get_content(%Source{arcana_document_id: nil}), do: {:error, :no_content}

  def get_content(%Source{arcana_document_id: doc_id}) do
    content =
      from(d in "arcana_documents",
        where: d.id == type(^doc_id, :binary_id),
        select: d.content
      )
      |> Repo.one()

    case content do
      nil -> {:error, :no_content}
      content -> {:ok, content}
    end
  end

  def find_by_url(url) when is_binary(url) do
    Repo.get_by(Source, url: url)
  end

  def get_by_arcana_document_id(document_id) when is_binary(document_id) do
    Repo.get_by(Source, arcana_document_id: document_id)
  end

  # Keyed documents are identified by their key and may share text, so only
  # unkeyed sources take part in content-hash dedup.
  def find_by_content_hash(hash) when is_binary(hash) do
    Source
    |> where([s], s.content_hash == ^hash and is_nil(s.key))
    |> Repo.one()
  end

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, []), do: query

  defp maybe_filter_tags(query, tags) do
    where(query, [s], fragment("? && ?", s.tags, ^tags))
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    where(query, [s], s.status == ^status)
  end

  defp maybe_filter_collection(query, nil), do: query

  defp maybe_filter_collection(query, collection) do
    where(query, [s], s.collection == ^collection)
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  defp normalize_int(nil), do: 0
  defp normalize_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp normalize_int(n) when is_integer(n), do: n

  defp format_bytes(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end
end

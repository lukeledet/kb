defmodule KB.Ingest do
  @moduledoc """
  Batched, concurrent replacement for `Arcana.ingest/2`.

  Arcana 1.6's ingest path (`Arcana.Ingest.embed_and_store_chunks/3`) embeds one
  chunk per HTTP request, strictly sequentially. For an OpenRouter-backed
  embedder that is the ingestion bottleneck: throughput is capped at one request
  per chunk, and the only parallelism is the number of concurrent Oban workers.

  This module reuses Arcana's chunker, schemas, and embedder configuration but
  embeds all of a document's chunks through the configured embedder's
  `embed_batch/2` (which batches and parallelizes the API calls), then
  bulk-inserts the chunk rows. It returns the same `{:ok, %Arcana.Document{}}`
  contract as `Arcana.ingest/2` so the workers are a drop-in swap.

  Embedding happens before anything is written, and the document and its
  chunks are then inserted in one transaction. A failed attempt leaves nothing
  behind, and a caller that needs to swap one document for another can run
  `insert_document/4` inside its own transaction (see `KB.Documents`).

  GraphRAG extraction is intentionally omitted — it is disabled in this app
  (`Arcana.Graph.enabled?/0` is false), matching the behaviour of the previous
  `Arcana.ingest/2` calls here.
  """

  alias Arcana.{Chunk, Chunker, Collection, Config, Document, Embedder}

  # Rows per insert_all statement, keeping Postgres' 65535 bound-parameter limit
  # comfortably out of reach (~8 params/row).
  @insert_batch_size 1000

  @doc """
  Ingests `text` into a document with embedded chunks.

  Accepts the same options used by the workers today: `:repo` (required),
  `:source_id`, `:metadata`, `:collection`, and any chunker options
  (`:chunk_size`, `:chunk_overlap`, `:format`, `:size_unit`).

  Returns `{:ok, document}` on success or `{:error, reason}` on failure. On
  failure nothing has been written, so a failed attempt — including any Oban
  retry — leaves nothing behind.
  """
  def ingest(text, opts) when is_binary(text) do
    repo = Keyword.fetch!(opts, :repo)
    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap, :format, :size_unit])
    chunks = Chunker.chunk(Config.resolve_chunker(opts), text, chunk_opts)

    with {:ok, embedded} <- embed(chunks) do
      repo.transaction(fn -> insert_document(repo, text, embedded, opts) end)
    end
  end

  @doc """
  Embeds `chunks` and pairs each with its vector.

  Each chunk is a map with `:text` and `:chunk_index`, and optionally
  `:token_count` and `:metadata`, as `Arcana.Chunker` returns them. `opts`
  are passed to the embedder, such as `hedge_after` (see
  `KB.Embedder.OpenAI`).
  """
  def embed(chunks, opts \\ [])
  def embed([], _opts), do: {:ok, []}

  def embed(chunks, opts) do
    texts = Enum.map(chunks, & &1.text)
    {embedder, config_opts} = Config.embedder()

    case Embedder.embed_batch({embedder, Keyword.merge(config_opts, opts)}, texts) do
      {:ok, embeddings} when length(embeddings) == length(chunks) ->
        {:ok, Enum.zip(chunks, embeddings)}

      {:ok, embeddings} ->
        {:error, {:embedding_count_mismatch, expected: length(chunks), got: length(embeddings)}}

      {:error, reason} ->
        {:error, {:embedding_failed, reason}}
    end
  end

  @doc """
  Inserts a completed document and its embedded chunks, returning the document.

  Run it inside a transaction: it raises on failure, and a document whose
  chunk insert failed partway must not survive. `embedded` is what `embed/1`
  returns. Takes `:source_id`, `:metadata`, and `:collection` from `opts`.
  """
  def insert_document(repo, text, embedded, opts) do
    {collection_name, collection_description} =
      parse_collection(Keyword.get(opts, :collection, "default"))

    {:ok, collection} = Collection.get_or_create(collection_name, repo, collection_description)

    # Built with change/2 rather than Document.changeset/2, which requires
    # non-blank content. An empty keyed document (an empty file in a synced
    # folder) is still a document: it has text "" and no chunks.
    document =
      %Document{}
      |> Ecto.Changeset.change(%{
        content: text,
        source_id: Keyword.get(opts, :source_id),
        metadata: Keyword.get(opts, :metadata, %{}),
        status: :completed,
        chunk_count: length(embedded),
        collection_id: collection.id
      })
      |> repo.insert!()

    embedded
    |> build_rows(document)
    |> Enum.chunk_every(@insert_batch_size)
    |> Enum.each(&repo.insert_all(Chunk, &1))

    document
  end

  # insert_all bypasses changesets (and thus field defaults/timestamps), so
  # build_rows sets every column explicitly.
  defp build_rows(embedded, document) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Enum.map(embedded, fn {chunk, embedding} ->
      %{
        id: Ecto.UUID.generate(),
        text: chunk.text,
        embedding: embedding,
        chunk_index: chunk.chunk_index,
        token_count: Map.get(chunk, :token_count),
        document_id: document.id,
        metadata: chunk_metadata(chunk),
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  # Only a heading path is worth keeping. Arcana's chunker also reports byte
  # offsets, but nothing reads them.
  defp chunk_metadata(%{metadata: %{"heading_path" => path}}), do: %{"heading_path" => path}
  defp chunk_metadata(_chunk), do: %{}

  defp parse_collection(name) when is_binary(name), do: {name, nil}
  defp parse_collection(%{name: name, description: desc}), do: {name, desc}
  defp parse_collection(%{name: name}), do: {name, nil}
end

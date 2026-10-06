defmodule KB.Documents do
  @moduledoc """
  Keyed documents: pages a caller names by collection and key and keeps in
  step with an outside copy, such as the files in a git repository.

  A keyed document is a `KB.Sources.Source` row with a `key`, and its id never
  changes. When its text changes, the new version is indexed in the
  background (`KB.Workers.SyncDocument`) while the old one stays searchable.
  `index/4` then swaps them in one transaction: it inserts the new Arcana
  document, points the source at it, and deletes the old one. Search reaches
  chunks only through `sources.arcana_document_id`, so a reader sees one
  version or the other, never both and never neither.

  Every version is identified by the SHA-256 of its exact bytes. The swap only
  happens if the source still wants that version, so a slow job for an old
  version can never overwrite a newer one.
  """

  import Ecto.Query

  alias KB.{Markdown, Repo}
  alias KB.Sources.Source
  alias KB.Workers.SyncDocument

  @collection_format ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @keyed_types ~w(markdown text transcript)
  @max_content_bytes 10_000_000
  @max_key_bytes 1024
  @max_title_chars 255

  # A prune that would delete more than this share of a collection, and more
  # than @prune_floor documents, needs `force`. It stops a sync with a wrong
  # include pattern from emptying the collection.
  @prune_share 0.2
  @prune_floor 5

  # Someone is usually waiting on a keyed document, so an embedding request
  # that has not answered by now is sent again. See KB.Embedder.OpenAI.
  @hedge_after_ms 2_000

  @type result :: :created | :updated | :unchanged | :pending | :retried

  @doc """
  Creates or replaces the document at `key` in `collection`.

  Returns `{:ok, %{source: source, result: result, warnings: warnings}}`:

    * `:created` - a new key; the document is searchable once indexed.
    * `:updated` - new text for an existing key; the old text stays
      searchable until the new text is indexed.
    * `:unchanged` - the latest version already has this text.
    * `:pending` - this text is already queued or being indexed.
    * `:retried` - this text failed to index before and is queued again.

  The text's hash is all that decides whether anything changed, so passing a
  different title or tags with the same text is `:unchanged`. Pass
  `force: true` to index it again anyway.

  ## Options

    * `:title` - overrides the frontmatter title and the first H1
    * `:tags` - added to the tags the frontmatter declares
    * `:metadata` - replaces the stored metadata map
    * `:source_type` - `markdown` (default), `text`, or `transcript`. Only
      markdown gets frontmatter and heading-aware chunks.
    * `:force` - index again even when the text is unchanged
  """
  @spec upsert(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{source: Source.t(), result: result(), warnings: [String.t()]}}
          | {:error, String.t()}
  def upsert(collection, key, content, opts \\ []) do
    with :ok <- validate_collection(collection),
         :ok <- validate_key(key),
         :ok <- validate_content(content),
         {:ok, attrs} <- validate_attrs(opts) do
      version = build_version(collection, key, content, attrs)

      case Repo.transaction(fn -> do_upsert(collection, key, version, attrs, opts) end) do
        {:ok, result} ->
          {:ok, Map.put(result, :warnings, version.warnings)}

        # Two requests created the same key at once and this one lost. The
        # row exists now, so a second pass takes the update path.
        {:error, :key_taken} ->
          case Repo.transaction(fn -> do_upsert(collection, key, version, attrs, opts) end) do
            {:ok, result} -> {:ok, Map.put(result, :warnings, version.warnings)}
            {:error, reason} -> {:error, inspect(reason)}
          end

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp do_upsert(collection, key, version, attrs, opts) do
    force = Keyword.get(opts, :force, false)

    case lock_key(collection, key) do
      nil ->
        source = insert!(collection, key, version)
        enqueue!(source, version, attrs)
        %{source: source, result: :created}

      %Source{content_hash: hash, status: status} = source when hash == version.hash ->
        cond do
          force -> requeue!(source, version, attrs, :updated)
          status == "failed" -> requeue!(source, version, attrs, :retried)
          # Enqueue anyway: uniqueness folds it into the job already queued,
          # and if that job was lost, this replaces it rather than leaving
          # the document pending forever.
          status in ~w(pending processing) -> requeue!(source, version, attrs, :pending)
          true -> %{source: source, result: :unchanged}
        end

      source ->
        requeue!(source, version, attrs, :updated)
    end
  end

  defp insert!(collection, key, version) do
    %Source{}
    |> Source.changeset(
      Map.merge(version.fields, %{
        collection: collection,
        key: key,
        slug: Markdown.slug(key),
        content_hash: version.hash,
        status: "pending"
      })
    )
    |> Repo.insert()
    |> case do
      {:ok, source} -> source
      {:error, %Ecto.Changeset{errors: [key: _]}} -> Repo.rollback(:key_taken)
      {:error, changeset} -> Repo.rollback(changeset_error(changeset))
    end
  end

  # The title, tags and frontmatter of an indexed document describe the text
  # that is searchable now, so they change at the swap, not here.
  defp requeue!(source, version, attrs, result) do
    source =
      source
      |> Ecto.Changeset.change(content_hash: version.hash, status: "pending", error: nil)
      |> Repo.update!()

    enqueue!(source, version, attrs)
    %{source: source, result: result}
  end

  defp enqueue!(source, version, attrs) do
    %{
      source_id: source.id,
      content_hash: version.hash,
      content: version.content,
      attrs: attrs
    }
    |> SyncDocument.new()
    |> Oban.insert!()
  end

  @doc """
  Indexes one version of a keyed document and swaps it in.

  Called by `KB.Workers.SyncDocument`. Returns `:ok`, `{:cancel, reason}`
  when the version is no longer wanted (the document was deleted, or newer
  text arrived), or `{:error, reason}` when indexing failed and is worth
  retrying.
  """
  @spec index(Ecto.UUID.t(), String.t(), String.t(), map()) ::
          :ok | {:cancel, atom()} | {:error, term()}
  def index(source_id, hash, content, attrs) do
    with {:ok, source} <- wanted(source_id, hash),
         :ok <- mark(source_id, hash, "processing", nil),
         version = build_version(source.collection, source.key, content, attrs),
         {:ok, embedded} <- KB.Ingest.embed(chunks(version), hedge_after: @hedge_after_ms) do
      Repo.transaction(fn -> swap!(source_id, version, embedded) end)
      |> case do
        {:ok, _source} -> :ok
        {:error, reason} when reason in [:source_deleted, :superseded] -> {:cancel, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp wanted(source_id, hash) do
    case Repo.get(Source, source_id) do
      nil -> {:cancel, :source_deleted}
      %Source{content_hash: ^hash} = source -> {:ok, source}
      _newer -> {:cancel, :superseded}
    end
  end

  defp swap!(source_id, version, embedded) do
    source = Repo.one(from s in Source, where: s.id == ^source_id, lock: "FOR UPDATE")

    cond do
      source == nil -> Repo.rollback(:source_deleted)
      source.content_hash != version.hash -> Repo.rollback(:superseded)
      true -> :ok
    end

    old_document_id = source.arcana_document_id

    document =
      KB.Ingest.insert_document(Repo, version.content, embedded,
        source_id: source.id,
        collection: source.collection,
        metadata: %{"collection" => source.collection, "key" => source.key}
      )

    source =
      source
      |> Source.changeset(
        Map.merge(version.fields, %{
          arcana_document_id: document.id,
          chunk_count: document.chunk_count,
          status: "completed",
          error: nil
        })
      )
      |> Repo.update!()

    # Only markdown has wikilinks; a page that stopped being markdown drops
    # the links its earlier version had.
    KB.Links.replace!(source, if(source.source_type == "markdown", do: version.content, else: ""))

    # The source no longer points at the old document, so deleting it (and,
    # by cascade, its chunks) is safe inside the same transaction.
    if old_document_id do
      case Arcana.delete(old_document_id, repo: Repo) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    source
  end

  @doc """
  Records the outcome of a failed attempt to index `hash`.

  The status only becomes `failed` after the last attempt. Until then the
  document stays `pending` with the error recorded, since a retry is coming.
  """
  def record_failure(source_id, hash, reason, final?) do
    mark(source_id, hash, if(final?, do: "failed", else: "pending"), inspect(reason))
  end

  defp mark(source_id, hash, status, error) do
    from(s in Source, where: s.id == ^source_id and s.content_hash == ^hash)
    |> Repo.update_all(set: [status: status, error: error, updated_at: now()])

    :ok
  end

  defp build_version(collection, key, content, attrs) do
    source_type = attrs["source_type"] || "markdown"

    parsed =
      if source_type == "markdown",
        do: Markdown.parse(content),
        else: %{frontmatter: %{}, body: content, title: nil, warnings: []}

    title =
      String.slice(attrs["title"] || parsed.title || default_title(key), 0, @max_title_chars)

    fields = %{
      title: title,
      source_type: source_type,
      tags: Enum.uniq((attrs["tags"] || []) ++ Markdown.tags(parsed.frontmatter)),
      frontmatter: parsed.frontmatter
    }

    %{
      collection: collection,
      key: key,
      content: content,
      body: parsed.body,
      hash: hash(content),
      fields: put_metadata(fields, attrs["metadata"]),
      warnings: parsed.warnings
    }
  end

  defp put_metadata(fields, nil), do: fields
  defp put_metadata(fields, metadata), do: Map.put(fields, :metadata, metadata)

  defp chunks(%{fields: %{source_type: "markdown", title: title}, body: body}),
    do: Markdown.chunk(body, title)

  defp chunks(%{content: content}),
    do: Arcana.Chunker.chunk(Arcana.Config.chunker(), content)

  defp default_title(key), do: key |> Path.basename() |> Path.rootname()

  defp lock_key(collection, key) do
    Repo.one(
      from s in Source,
        where: s.collection == ^collection and s.key == ^key,
        lock: "FOR UPDATE"
    )
  end

  @doc """
  Waits for upserted versions to finish indexing.

  `pairs` are `{source_id, content_hash}`. Returns a map from source id to
  the version's final state: `"completed"`, `"failed"`, `"superseded"` (newer
  text arrived), `"deleted"`, or the current status if `timeout` ms ran out
  first.
  """
  def await(pairs, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(Map.new(pairs), %{}, deadline)
  end

  defp do_await(waiting, done, _deadline) when map_size(waiting) == 0, do: done

  defp do_await(waiting, done, deadline) do
    ids = Map.keys(waiting)

    rows =
      from(s in Source, where: s.id in ^ids, select: {s.id, {s.content_hash, s.status}})
      |> Repo.all()
      |> Map.new()

    states = Map.new(waiting, fn {id, hash} -> {id, version_state(rows[id], hash)} end)

    {finished, open} =
      Enum.split_with(states, fn {_id, state} -> state not in ~w(pending processing) end)

    done = Map.merge(done, Map.new(finished))

    if open == [] or System.monotonic_time(:millisecond) >= deadline do
      Map.merge(done, Map.new(open))
    else
      Process.sleep(200)
      do_await(Map.take(waiting, Enum.map(open, &elem(&1, 0))), done, deadline)
    end
  end

  defp version_state(nil, _hash), do: "deleted"
  defp version_state({hash, status}, hash), do: status
  defp version_state({_other, _status}, _hash), do: "superseded"

  ## Reading

  @doc "The document at `key` in `collection`."
  def get(collection, key) do
    case Repo.get_by(Source, collection: collection, key: key) do
      nil -> {:error, :not_found}
      source -> {:ok, source}
    end
  end

  @doc """
  The searchable text of `source`, byte for byte, and its SHA-256.

  While a new version is indexing this is still the old one, and the hash
  says which version it is.
  """
  def content(source) do
    with {:ok, content} <- KB.Sources.get_content(source), do: {:ok, content, hash(content)}
  end

  @doc """
  Documents in `collection` with their searchable text, by `:keys` or by key
  `:prefix`, ordered by key.

  Returns `%{documents: [{source, content}], missing: keys, truncated: bool}`.
  A document that has not been indexed yet comes back with `nil` content.
  `:limit` caps how many documents come back (default 50, at most 500).
  """
  def multi_get(collection, opts) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)

    query =
      from s in Source,
        left_join: d in "arcana_documents",
        on: d.id == s.arcana_document_id,
        where: s.collection == ^collection and not is_nil(s.key),
        order_by: s.key,
        limit: ^(limit + 1),
        select: {s, d.content}

    {query, keys} =
      case {opts[:keys], opts[:prefix]} do
        {keys, _} when is_list(keys) ->
          {where(query, [s], s.key in ^keys), keys}

        {_, prefix} when is_binary(prefix) ->
          {where(query, [s], like(s.key, ^like_prefix(prefix))), nil}

        _ ->
          {query, nil}
      end

    rows = Repo.all(query)
    documents = Enum.take(rows, limit)
    found = MapSet.new(documents, fn {source, _content} -> source.key end)

    %{
      documents: documents,
      missing: if(keys, do: Enum.reject(keys, &MapSet.member?(found, &1)), else: []),
      truncated: length(rows) > limit
    }
  end

  @doc false
  def like_prefix(prefix), do: String.replace(prefix, ~r/[\\%_]/, "\\\\\\0") <> "%"

  ## Removing and renaming

  @doc """
  Deletes the documents at `keys` in `collection`, with their chunks.

  Returns `{:ok, %{deleted: keys, not_found: keys}}`. An indexing job still
  running for a deleted document finds it gone and stops.
  """
  def delete(collection, keys) when is_list(keys) do
    Repo.transaction(fn ->
      sources =
        Repo.all(
          from s in Source,
            where: s.collection == ^collection and s.key in ^keys,
            lock: "FOR UPDATE"
        )

      Enum.each(sources, &delete_source!/1)
      deleted = sources |> Enum.map(& &1.key) |> Enum.sort()
      %{deleted: deleted, not_found: keys -- deleted}
    end)
  end

  defp delete_source!(source) do
    Repo.delete!(source)

    if source.arcana_document_id do
      case Arcana.delete(source.arcana_document_id, repo: Repo) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  @doc """
  Moves the document at `from` to `to` without indexing it again.

  Its id, text and chunks stay the same. Returns `{:error, :not_found}` when
  nothing is at `from`, and `{:error, :key_taken}` when something is at `to`.
  """
  def rename(collection, from, to) do
    with :ok <- validate_key(to) do
      Repo.transaction(fn ->
        case lock_key(collection, from) do
          nil ->
            Repo.rollback(:not_found)

          source ->
            source
            |> Source.changeset(%{key: to, slug: Markdown.slug(to)})
            |> Repo.update()
            |> case do
              {:ok, source} -> source
              {:error, %Ecto.Changeset{errors: [key: _]}} -> Repo.rollback(:key_taken)
              {:error, changeset} -> Repo.rollback(changeset_error(changeset))
            end
        end
      end)
    end
  end

  ## Syncing

  @doc """
  Compares a caller's manifest with a collection.

  `manifest` is a list of `%{"key" => key, "content_hash" => sha256_hex}`,
  where the hash covers the exact bytes the caller would upload. Returns keys
  that are:

    * `missing` - in the manifest but not the collection
    * `stale` - in both with different text, or whose indexing failed
    * `pending` - in both with the same text, still being indexed
    * `extra` - in the collection but not the manifest

  plus `unchanged`, a count, and `renames`: pairs of an extra key and a
  missing key with the same text, which can be renamed instead of uploaded.

  With `prune: true` the extra keys are deleted and listed under `pruned`. A
  prune that would delete more than 20% of the collection, and more than 5
  documents, returns `{:error, {:prune_refused, count, total}}` unless
  `force: true` is passed too.

  A diff that finds nothing to upload and nothing extra left records the
  time as the collection's last sync.
  """
  def diff(collection, manifest, opts \\ []) do
    with :ok <- validate_collection(collection),
         {:ok, wanted} <- validate_manifest(manifest) do
      have =
        from(s in Source,
          where: s.collection == ^collection and not is_nil(s.key),
          select: {s.key, {s.content_hash, s.status}}
        )
        |> Repo.all()
        |> Map.new()

      compared =
        Enum.group_by(
          wanted,
          fn {key, hash} ->
            case have[key] do
              nil -> :missing
              {_hash, "failed"} -> :stale
              {^hash, status} when status in ~w(pending processing) -> :pending
              {^hash, _status} -> :unchanged
              _other -> :stale
            end
          end,
          fn {key, _hash} -> key end
        )

      extra = have |> Map.keys() |> Enum.reject(&Map.has_key?(wanted, &1)) |> Enum.sort()
      missing = Enum.sort(compared[:missing] || [])

      result = %{
        missing: missing,
        stale: Enum.sort(compared[:stale] || []),
        pending: Enum.sort(compared[:pending] || []),
        extra: extra,
        unchanged: length(compared[:unchanged] || []),
        renames: renames(missing, extra, wanted, have),
        pruned: []
      }

      with {:ok, result} <- maybe_prune(result, collection, map_size(have), opts) do
        if in_sync?(result), do: record_sync(collection)
        {:ok, result}
      end
    end
  end

  # An extra key holding exactly the text a missing key wants is the same
  # page under a new name. Each extra key pairs with at most one missing key.
  defp renames(missing, extra, wanted, have) do
    by_hash = Enum.group_by(extra, fn key -> elem(have[key], 0) end)

    {pairs, _left} =
      Enum.reduce(missing, {[], by_hash}, fn key, {pairs, by_hash} ->
        case Map.get(by_hash, wanted[key], []) do
          [from | rest] -> {[%{from: from, to: key} | pairs], Map.put(by_hash, wanted[key], rest)}
          [] -> {pairs, by_hash}
        end
      end)

    Enum.reverse(pairs)
  end

  defp maybe_prune(%{extra: []} = result, _collection, _total, _opts), do: {:ok, result}

  defp maybe_prune(result, collection, total, opts) do
    count = length(result.extra)

    cond do
      not Keyword.get(opts, :prune, false) ->
        {:ok, result}

      count > @prune_floor and count > total * @prune_share and
          not Keyword.get(opts, :force, false) ->
        {:error, {:prune_refused, count, total}}

      true ->
        with {:ok, %{deleted: deleted}} <- delete(collection, result.extra) do
          {:ok, %{result | pruned: deleted}}
        end
    end
  end

  defp in_sync?(result) do
    result.missing == [] and result.stale == [] and result.pending == [] and
      result.extra -- result.pruned == []
  end

  defp record_sync(collection) do
    now = now()

    Repo.insert_all(
      "collections",
      [%{name: collection, last_synced_at: now, inserted_at: now, updated_at: now}],
      on_conflict: [set: [last_synced_at: now, updated_at: now]],
      conflict_target: :name
    )
  end

  defp validate_manifest(manifest) when is_list(manifest) do
    Enum.reduce_while(manifest, {:ok, %{}}, fn
      %{"key" => key, "content_hash" => hash}, {:ok, acc} when is_binary(hash) ->
        hash = String.downcase(hash)

        cond do
          validate_key(key) != :ok ->
            {:halt, validate_key(key)}

          not Regex.match?(~r/\A[0-9a-f]{64}\z/, hash) ->
            {:halt, {:error, "content_hash for #{key} is not a SHA-256 hex digest"}}

          Map.has_key?(acc, key) ->
            {:halt, {:error, "manifest lists #{key} twice"}}

          true ->
            {:cont, {:ok, Map.put(acc, key, hash)}}
        end

      _entry, _acc ->
        {:halt, {:error, "each manifest entry needs a key and a content_hash"}}
    end)
  end

  defp validate_manifest(_), do: {:error, "manifest must be a list"}

  @doc """
  Counts and timestamps for a collection: documents by status, chunks, the
  keys that failed to index, when a document last changed, and when a sync
  last confirmed the collection matched its source.
  """
  def status(collection) do
    by_status =
      from(s in Source,
        where: s.collection == ^collection,
        group_by: s.status,
        select: {s.status, count(s.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{chunks: chunks, last_changed_at: last_changed_at} =
      Repo.one(
        from s in Source,
          where: s.collection == ^collection,
          select: %{chunks: coalesce(sum(s.chunk_count), 0), last_changed_at: max(s.updated_at)}
      )

    failed =
      Repo.all(
        from s in Source,
          where: s.collection == ^collection and s.status == "failed",
          order_by: s.key,
          limit: 50,
          select: %{id: s.id, key: s.key, title: s.title, error: s.error}
      )

    # A schemaless read returns the utc_datetime column without its zone.
    last_synced_at =
      Repo.one(from c in "collections", where: c.name == ^collection, select: c.last_synced_at)
      |> then(&(&1 && DateTime.from_naive!(&1, "Etc/UTC")))

    %{
      collection: collection,
      contexts: KB.Contexts.list(collection),
      documents: by_status |> Map.values() |> Enum.sum(),
      by_status: by_status,
      pending: Map.get(by_status, "pending", 0) + Map.get(by_status, "processing", 0),
      chunks: normalize_int(chunks),
      failed: failed,
      last_changed_at: last_changed_at,
      last_synced_at: last_synced_at
    }
  end

  @doc "Every collection with its document count, by name."
  def list_collections do
    from(s in Source,
      group_by: s.collection,
      order_by: s.collection,
      select: {s.collection, count(s.id)}
    )
    |> Repo.all()
    |> Enum.map(fn {name, count} -> %{name: name, documents: count} end)
  end

  @doc """
  The fields callers see for a document, without its text.
  """
  def summary(%Source{} = source) do
    %{
      id: source.id,
      collection: source.collection,
      key: source.key,
      title: source.title,
      source_type: source.source_type,
      status: source.status,
      tags: source.tags,
      frontmatter: source.frontmatter || %{},
      metadata: source.metadata || %{},
      url: source.url,
      content_hash: source.content_hash,
      chunk_count: source.chunk_count,
      error: source.error,
      updated_at: source.updated_at
    }
  end

  @doc """
  `summary/1` plus the text served and the hash of the whole stored version.

  `pending` is true while newer text is still being indexed: what is served
  is the version that is searchable now, not the latest upload. `text` may be
  one section of the stored version; `hash` is always of the whole version.
  """
  def detail(%Source{} = source, text, hash) do
    source
    |> summary()
    |> Map.merge(%{content: text, content_hash: hash, pending: source.content_hash != hash})
  end

  @doc """
  Adds the context notes (`KB.Contexts`) that apply to `source` to a
  `detail/3` or `summary/1` map, when there are any.
  """
  def with_context(map, %Source{collection: collection, key: key}) do
    case KB.Contexts.for_key(KB.Contexts.load([collection]), collection, key) do
      [] -> map
      notes -> Map.put(map, :context, notes)
    end
  end

  defp normalize_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp normalize_int(n), do: n

  @doc """
  Reloads sources by id, in the order given. Missing ids are left out.
  """
  def reload(ids) do
    by_id = from(s in Source, where: s.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
    for id <- ids, source = by_id[id], do: source
  end

  @doc """
  Queues every indexed document in `collection` to be chunked and embedded
  again from its stored text, and returns how many were queued.

  For when the chunking rules change. Each document keeps serving its
  current chunks until its new ones swap in, and keeps its title, tags and
  metadata.
  """
  def reindex(collection) do
    rows =
      Repo.all(
        from s in Source,
          join: d in "arcana_documents",
          on: d.id == s.arcana_document_id,
          where: s.collection == ^collection and not is_nil(s.key) and s.status == "completed",
          select: {s, d.content}
      )

    Enum.count(rows, fn {source, content} ->
      attrs = %{
        "title" => source.title,
        "tags" => source.tags,
        "source_type" => source.source_type
      }

      version = build_version(collection, source.key, content, attrs)

      version.hash == source.content_hash and
        match?({:ok, _}, Repo.transaction(fn -> requeue!(source, version, attrs, :updated) end))
    end)
  end

  @doc """
  Forgets a collection that no longer holds any documents, so its status
  stops answering. Returns `{:error, :not_empty}` while it has documents and
  `{:error, :not_found}` when there is nothing to forget.
  """
  def drop_collection(collection) do
    cond do
      Repo.exists?(from s in Source, where: s.collection == ^collection) ->
        {:error, :not_empty}

      Repo.delete_all(from c in "collections", where: c.name == ^collection) |> elem(0) > 0 ->
        :ok

      true ->
        {:error, :not_found}
    end
  end

  @doc "SHA-256 of `content`, as lowercase hex."
  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  ## Validation

  @doc false
  def validate_collection(name) when is_binary(name) do
    if Regex.match?(@collection_format, name),
      do: :ok,
      else: {:error, "collection must be 1-64 lowercase letters, digits, - or _"}
  end

  def validate_collection(_), do: {:error, "collection is required"}

  @doc false
  def validate_key(key) when is_binary(key) and key != "" do
    segments = String.split(key, "/")

    cond do
      byte_size(key) > @max_key_bytes -> {:error, "key is longer than #{@max_key_bytes} bytes"}
      String.starts_with?(key, "/") -> {:error, "key must be a relative path"}
      "" in segments -> {:error, "key has an empty path segment"}
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, "key must not contain . or .."}
      String.match?(key, ~r/[\x00-\x1f\x7f\\]/) -> {:error, "key has a control character or \\"}
      true -> :ok
    end
  end

  def validate_key(_), do: {:error, "key is required"}

  # Empty content is allowed: an empty file in a synced folder is stored with
  # no chunks rather than blocking every sync until someone fills it in.
  defp validate_content(content) when is_binary(content) do
    cond do
      byte_size(content) > @max_content_bytes ->
        {:error, "content is larger than #{@max_content_bytes} bytes"}

      not String.valid?(content) ->
        {:error, "content is not valid UTF-8"}

      # Postgres text columns cannot hold a NUL byte.
      String.contains?(content, <<0>>) ->
        {:error, "content contains a NUL byte"}

      true ->
        :ok
    end
  end

  defp validate_content(_), do: {:error, "content is required"}

  defp validate_attrs(opts) do
    attrs =
      opts
      |> Keyword.take([:title, :tags, :metadata, :source_type])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    cond do
      attrs["source_type"] && attrs["source_type"] not in @keyed_types ->
        {:error, "source_type must be one of: #{Enum.join(@keyed_types, ", ")}"}

      attrs["title"] && not (is_binary(attrs["title"]) and String.trim(attrs["title"]) != "") ->
        {:error, "title must be a non-empty string"}

      attrs["tags"] && not (is_list(attrs["tags"]) and Enum.all?(attrs["tags"], &is_binary/1)) ->
        {:error, "tags must be a list of strings"}

      attrs["metadata"] && not is_map(attrs["metadata"]) ->
        {:error, "metadata must be a JSON object"}

      true ->
        {:ok, attrs}
    end
  end

  defp changeset_error(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, "; ", fn {field, {message, _}} -> "#{field} #{message}" end)
  end
end

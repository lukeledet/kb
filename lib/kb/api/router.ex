defmodule KB.API.Router do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    json_decoder: Jason,
    length: 104_857_600

  plug :match
  plug :dispatch

  @accepted_extensions ~w(.pdf .epub)

  post "/ingest/file" do
    with {:ok, upload} <- get_upload(conn),
         {:ok, ext} <- validate_extension(upload.filename),
         {:ok, content} <- File.read(upload.path) do
      content_hash = hash(content)
      force = conn.body_params["force"] == "true"
      title = conn.body_params["title"] || upload.filename
      tags = parse_tags(conn.body_params["tags"])
      metadata = parse_metadata(conn.body_params["metadata"])
      source_type = String.trim_leading(ext, ".")

      case handle_dedup(:content_hash, content_hash, force) do
        {:existing, source} ->
          json_resp(conn, 200, source_json(source))

        :proceed ->
          {:ok, source} =
            KB.Sources.create_source(%{
              title: title,
              source_type: source_type,
              tags: tags,
              metadata: metadata,
              content_hash: content_hash
            })

          temp_path = KB.Workers.IngestContent.temp_path(source.id)
          File.write!(temp_path, content)

          %{source_id: source.id, temp_path: temp_path}
          |> KB.Workers.IngestContent.new()
          |> Oban.insert()

          json_resp(conn, 202, source_json(source))
      end
    else
      {:error, :no_file} ->
        json_resp(conn, 400, %{error: "file field is required"})

      {:error, :unsupported_extension, ext} ->
        json_resp(conn, 400, %{error: "Unsupported file type: #{ext}. Accepted: .pdf, .epub"})

      {:error, reason} ->
        json_resp(conn, 500, %{error: "Failed to read file: #{inspect(reason)}"})
    end
  end

  post "/ingest/text" do
    params = conn.body_params

    if params["key"] do
      ingest_keyed_text(conn, params)
    else
      ingest_text(conn, params)
    end
  end

  post "/ingest/url" do
    params = conn.body_params

    with {:ok, url} <- require_url(params),
         :ok <- validate_url(url) do
      force = params["force"] == true
      title = params["title"] || url
      tags = parse_tags(params["tags"])
      metadata = parse_metadata(params["metadata"])

      case handle_dedup(:url, url, force) do
        {:existing, source} ->
          json_resp(conn, 200, source_json(source))

        :proceed ->
          {:ok, source} =
            KB.Sources.create_source(%{
              title: title,
              url: url,
              source_type: "url",
              tags: tags,
              metadata: metadata
            })

          %{source_id: source.id}
          |> KB.Workers.IngestUrl.new()
          |> Oban.insert()

          json_resp(conn, 202, source_json(source))
      end
    else
      {:error, message} ->
        json_resp(conn, 400, %{error: message})
    end
  end

  post "/search" do
    with {:ok, query, opts} <- KB.Search.Params.parse(conn.body_params) do
      case KB.Search.run(query, opts) do
        {:ok, search} ->
          json_resp(conn, 200, KB.Search.Response.render(query, search))

        {:error, reason} ->
          json_resp(conn, 500, %{error: "Search failed: #{inspect(reason)}"})
      end
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  get "/stats" do
    json_resp(conn, 200, Map.put(KB.Sources.stats(), :search, KB.Search.Stats.snapshot()))
  end

  get "/sources/:id" do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %KB.Sources.Source{} = source <- KB.Sources.get_source(id) do
      json_resp(conn, 200, source_detail_json(source))
    else
      _ -> json_resp(conn, 404, %{error: "Source not found"})
    end
  end

  get "/sources/:id/content" do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %KB.Sources.Source{} = source <- KB.Sources.get_source(id) do
      case KB.Sources.get_content(source) do
        {:ok, content} ->
          json_resp(conn, 200, source_content_json(source, content))

        {:error, :no_content} ->
          json_resp(conn, 409, %{error: "Source has no content (status: #{source.status})"})
      end
    else
      _ -> json_resp(conn, 404, %{error: "Source not found"})
    end
  end

  get "/sources/:id/related" do
    conn = fetch_query_params(conn)

    with {:ok, _} <- Ecto.UUID.cast(id),
         %KB.Sources.Source{} <- KB.Sources.get_source(id) do
      related(conn, id, conn.query_params)
    else
      _ -> json_resp(conn, 404, %{error: "Source not found"})
    end
  end

  patch "/sources/:id" do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %KB.Sources.Source{} = source <- KB.Sources.get_source(id),
         {:ok, attrs} <- update_attrs(source, conn.body_params),
         {:ok, source} <- KB.Sources.update_source(source, attrs) do
      json_resp(conn, 200, source_detail_json(source))
    else
      {:error, message} when is_binary(message) ->
        json_resp(conn, 400, %{error: message})

      _ ->
        json_resp(conn, 404, %{error: "Source not found"})
    end
  end

  forward "/collections", to: KB.API.Collections

  match _ do
    json_resp(conn, 404, %{error: "Not found"})
  end

  defp ingest_text(conn, params) do
    with {:ok, text} <- require_text(params),
         {:ok, source_type} <- validate_source_type(params["source_type"]),
         {:ok, collection} <- optional_collection(params["collection"]) do
      content_hash = hash(text)
      force = params["force"] == true
      title = params["title"] || "Untitled"
      tags = params["tags"] || []
      metadata = parse_metadata(params["metadata"])

      case handle_dedup(:content_hash, content_hash, force) do
        {:existing, source} ->
          json_resp(conn, 200, source_json(source))

        :proceed ->
          {:ok, source} =
            KB.Sources.create_source(%{
              title: title,
              source_type: source_type,
              tags: tags,
              metadata: metadata,
              content_hash: content_hash,
              collection: collection
            })

          temp_path = KB.Workers.IngestContent.temp_path(source.id)
          File.write!(temp_path, text)

          %{source_id: source.id, temp_path: temp_path}
          |> KB.Workers.IngestContent.new()
          |> Oban.insert()

          json_resp(conn, 202, source_json(source))
      end
    else
      {:error, message} ->
        json_resp(conn, 400, %{error: message})
    end
  end

  # A text with a key is a document the caller will update in place. See
  # KB.Documents.
  defp ingest_keyed_text(conn, params) do
    with {:ok, text} <- require_keyed_text(params),
         {:ok, collection} <- require_collection(params["collection"]),
         {:ok, upserted} <-
           KB.Documents.upsert(collection, params["key"], text,
             title: params["title"],
             tags: params["tags"] && parse_tags(params["tags"]),
             metadata: params["metadata"] && parse_metadata(params["metadata"]),
             source_type: params["source_type"],
             force: params["force"] == true
           ) do
      %{source: source, result: result, warnings: warnings} = upserted
      waited = params["wait"] == true and result != :unchanged

      status =
        if waited,
          do: Map.fetch!(KB.Documents.await([{source.id, source.content_hash}]), source.id),
          else: source.status

      # Title and chunk count change at the swap; report them as they are now.
      source = if waited, do: KB.Documents.reload([source.id]) |> List.first(source), else: source

      code = if result in [:created, :updated, :retried] and not waited, do: 202, else: 200

      json_resp(
        conn,
        code,
        source
        |> source_json()
        |> Map.merge(%{
          status: status,
          collection: collection,
          key: source.key,
          result: result,
          content_hash: source.content_hash,
          chunk_count: source.chunk_count,
          warnings: warnings
        })
      )
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  defp require_collection(name) when is_binary(name) do
    with :ok <- KB.Documents.validate_collection(name), do: {:ok, name}
  end

  defp require_collection(_), do: {:error, "collection is required with key"}

  defp optional_collection(nil), do: {:ok, "library"}
  defp optional_collection(name), do: require_collection(name)

  # find_related raises for a source that has no chunks yet.
  defp related(conn, id, params) do
    limit =
      case Integer.parse(params["limit"] || "") do
        {n, ""} when n > 0 -> min(n, 50)
        _ -> 5
      end

    related = KB.Search.find_related(id, limit: limit, collection: params["collection"])
    json_resp(conn, 200, %{source_id: id, related: related})
  rescue
    error in RuntimeError -> json_resp(conn, 409, %{error: error.message})
  end

  defp get_upload(conn) do
    case conn.body_params do
      %{"file" => %Plug.Upload{} = upload} -> {:ok, upload}
      _ -> {:error, :no_file}
    end
  end

  defp validate_extension(filename) do
    ext = Path.extname(filename) |> String.downcase()

    if ext in @accepted_extensions do
      {:ok, ext}
    else
      {:error, :unsupported_extension, ext}
    end
  end

  defp require_text(%{"text" => text}) when is_binary(text) and text != "", do: {:ok, text}
  defp require_text(_), do: {:error, "text field is required"}

  # A keyed document may be empty, like the empty file it mirrors.
  defp require_keyed_text(%{"text" => text}) when is_binary(text), do: {:ok, text}
  defp require_keyed_text(_), do: {:error, "text field is required"}

  defp require_url(%{"url" => url}) when is_binary(url) and url != "", do: {:ok, url}
  defp require_url(_), do: {:error, "url field is required"}

  # A PATCH may carry a title, a metadata map, or both — but not neither.
  defp update_attrs(source, params) do
    with {:ok, attrs} <- put_title(%{}, params),
         {:ok, attrs} <- put_metadata(attrs, source, params) do
      if map_size(attrs) == 0 do
        {:error, "title or metadata field is required"}
      else
        {:ok, attrs}
      end
    end
  end

  defp put_title(attrs, %{"title" => title}) when is_binary(title) do
    case String.trim(title) do
      "" -> {:error, "title field is required"}
      title -> {:ok, Map.put(attrs, :title, title)}
    end
  end

  defp put_title(_attrs, %{"title" => _}), do: {:error, "title must be a string"}
  defp put_title(attrs, _), do: {:ok, attrs}

  # Metadata merges into what is already stored, so a caller can add one key
  # without resending the rest. An explicit null drops the key.
  defp put_metadata(attrs, source, %{"metadata" => metadata}) when is_map(metadata) do
    merged =
      (source.metadata || %{})
      |> Map.merge(metadata)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    {:ok, Map.put(attrs, :metadata, merged)}
  end

  defp put_metadata(_attrs, _source, %{"metadata" => _}),
    do: {:error, "metadata must be a JSON object"}

  defp put_metadata(attrs, _source, _), do: {:ok, attrs}

  defp source_detail_json(source) do
    %{
      id: source.id,
      title: source.title,
      url: source.url,
      source_type: source.source_type,
      status: source.status,
      tags: source.tags,
      metadata: source.metadata || %{},
      chunk_count: source.chunk_count,
      error: source.error,
      collection: source.collection,
      key: source.key,
      frontmatter: source.frontmatter || %{}
    }
  end

  defp source_content_json(source, content) do
    %{
      id: source.id,
      title: source.title,
      url: source.url,
      source_type: source.source_type,
      chunk_count: source.chunk_count,
      content: content
    }
  end

  defp validate_url(url) do
    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      :ok
    else
      {:error, "Invalid URL: must start with http:// or https://"}
    end
  end

  defp validate_source_type(nil), do: {:ok, "text"}
  defp validate_source_type("text"), do: {:ok, "text"}
  defp validate_source_type("transcript"), do: {:ok, "transcript"}

  defp validate_source_type(other),
    do: {:error, "Invalid source_type: #{other}. Must be text or transcript"}

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags) when is_binary(tags),
    do: String.split(tags, ",", trim: true) |> Enum.map(&String.trim/1)

  defp parse_tags(tags) when is_list(tags), do: tags

  defp parse_metadata(nil), do: %{}

  defp parse_metadata(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp parse_metadata(map) when is_map(map), do: map

  defp hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp handle_dedup(:content_hash, hash, force) do
    case KB.Sources.find_by_content_hash(hash) do
      nil ->
        :proceed

      existing when force ->
        KB.Sources.delete_source(existing)
        :proceed

      existing ->
        {:existing, existing}
    end
  end

  defp handle_dedup(:url, url, force) do
    case KB.Sources.find_by_url(url) do
      nil ->
        :proceed

      existing when force ->
        KB.Sources.delete_source(existing)
        :proceed

      existing ->
        {:existing, existing}
    end
  end

  defp source_json(source) do
    %{
      id: source.id,
      title: source.title,
      source_type: source.source_type,
      status: source.status,
      tags: source.tags
    }
  end

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end

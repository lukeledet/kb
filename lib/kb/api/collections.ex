defmodule KB.API.Collections do
  @moduledoc """
  HTTP endpoints for keyed documents, mounted at `/api/collections`.

  Keys are file paths and contain slashes, so they travel in JSON bodies and
  query strings rather than in the URL path. Request bodies are parsed by
  `KB.API.Router` before they are forwarded here.
  """

  use Plug.Router

  alias KB.Documents

  plug :match
  plug :dispatch

  @max_batch 500
  @default_wait_seconds 60
  @max_wait_seconds 120

  get "/" do
    json_resp(conn, 200, %{collections: Documents.list_collections()})
  end

  get "/:collection" do
    with :ok <- Documents.validate_collection(collection) do
      json_resp(conn, 200, Documents.status(collection))
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  delete "/:collection" do
    case Documents.drop_collection(collection) do
      :ok ->
        json_resp(conn, 200, %{dropped: collection})

      {:error, :not_empty} ->
        json_resp(conn, 409, %{error: "#{collection} still has documents; delete them first"})

      {:error, :not_found} ->
        json_resp(conn, 404, %{error: "No collection named #{collection}"})
    end
  end

  post "/:collection/reindex" do
    with :ok <- Documents.validate_collection(collection) do
      json_resp(conn, 202, %{collection: collection, queued: Documents.reindex(collection)})
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  get "/:collection/links" do
    conn = fetch_query_params(conn)

    with :ok <- Documents.validate_collection(collection),
         {:ok, source, slug} <- link_subject(collection, conn.query_params) do
      json_resp(conn, 200, %{
        collection: collection,
        slug: slug,
        document: source && Documents.summary(source),
        backlinks: KB.Links.backlinks(collection, slug),
        outlinks: if(source, do: KB.Links.outlinks(source), else: [])
      })
    else
      {:error, status, message} -> json_resp(conn, status, %{error: message})
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  get "/:collection/link_report" do
    with :ok <- Documents.validate_collection(collection) do
      json_resp(conn, 200, KB.Links.report(collection))
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  post "/:collection/relink" do
    with :ok <- Documents.validate_collection(collection) do
      json_resp(conn, 200, %{collection: collection, relinked: KB.Links.relink(collection)})
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  get "/:collection/contexts" do
    with :ok <- Documents.validate_collection(collection) do
      json_resp(conn, 200, %{collection: collection, contexts: KB.Contexts.list(collection)})
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  put "/:collection/contexts" do
    params = conn.body_params

    case KB.Contexts.put(collection, params["prefix"] || "", params["description"]) do
      {:ok, context} -> json_resp(conn, 200, Map.put(context, :collection, collection))
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  post "/:collection/diff" do
    params = conn.body_params
    opts = [prune: params["prune"] == true, force: params["force"] == true]

    case Documents.diff(collection, params["manifest"], opts) do
      {:ok, diff} ->
        json_resp(conn, 200, diff)

      {:error, {:prune_refused, count, total}} ->
        json_resp(conn, 409, %{
          error:
            "prune would delete #{count} of #{total} documents in #{collection}; " <>
              "pass force: true if that is intended"
        })

      {:error, message} when is_binary(message) ->
        json_resp(conn, 400, %{error: message})

      {:error, reason} ->
        json_resp(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/:collection/documents" do
    params = conn.body_params

    with :ok <- Documents.validate_collection(collection),
         {:ok, documents} <- require_documents(params["documents"]),
         {:ok, wait} <- parse_wait(params) do
      force = params["force"] == true
      results = Enum.map(documents, &upsert(collection, &1, force))
      results = if wait, do: await(results, wait), else: results

      json_resp(conn, 200, %{
        collection: collection,
        results: Enum.map(results, &result_json/1),
        counts: count_results(results),
        errors: Enum.count(results, &Map.has_key?(&1, :error))
      })
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  get "/:collection/documents" do
    conn = fetch_query_params(conn)

    with {:ok, key} <- require_string(conn.query_params["key"], "key"),
         {:ok, source} <- fetch(collection, key),
         {:ok, content, hash} <- fetch_content(source),
         {:ok, text} <- maybe_section(content, conn.query_params["section"]) do
      json_resp(
        conn,
        200,
        source |> Documents.detail(text, hash) |> Documents.with_context(source)
      )
    else
      {:error, status, message} -> json_resp(conn, status, %{error: message})
    end
  end

  post "/:collection/documents/get" do
    params = conn.body_params

    with :ok <- Documents.validate_collection(collection),
         {:ok, selector} <- selector(params),
         {:ok, limit} <- parse_limit(params["limit"]) do
      %{documents: documents, missing: missing, truncated: truncated} =
        Documents.multi_get(collection, [{:limit, limit} | selector])

      include_content = params["include_content"] != false

      json_resp(conn, 200, %{
        documents:
          Enum.map(documents, fn {source, content} ->
            multi_json(source, content, include_content)
          end),
        missing: missing,
        truncated: truncated
      })
    else
      {:error, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  post "/:collection/delete" do
    with :ok <- Documents.validate_collection(collection),
         {:ok, keys} <- require_keys(conn.body_params["keys"]),
         {:ok, result} <- Documents.delete(collection, keys) do
      json_resp(conn, 200, result)
    else
      {:error, message} when is_binary(message) -> json_resp(conn, 400, %{error: message})
      {:error, reason} -> json_resp(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/:collection/rename" do
    params = conn.body_params

    with {:ok, from} <- require_string(params["from"], "from"),
         {:ok, to} <- require_string(params["to"], "to") do
      case Documents.rename(collection, from, to) do
        {:ok, source} ->
          json_resp(conn, 200, Documents.summary(source))

        {:error, :not_found} ->
          json_resp(conn, 404, %{error: "No document at #{from}"})

        {:error, :key_taken} ->
          json_resp(conn, 409, %{error: "A document already exists at #{to}"})

        {:error, message} ->
          json_resp(conn, 400, %{error: to_string(message)})
      end
    else
      {:error, _status, message} -> json_resp(conn, 400, %{error: message})
    end
  end

  match _ do
    json_resp(conn, 404, %{error: "Not found"})
  end

  ## Upserts

  defp upsert(collection, %{"key" => key, "content" => content} = doc, force) do
    opts = [
      title: doc["title"],
      tags: doc["tags"],
      metadata: doc["metadata"],
      source_type: doc["source_type"],
      force: force
    ]

    case Documents.upsert(collection, key, content, opts) do
      {:ok, %{source: source, result: result, warnings: warnings}} ->
        %{key: key, source: source, result: result, status: source.status, warnings: warnings}

      {:error, message} ->
        %{key: key, error: message}
    end
  end

  defp upsert(_collection, doc, _force) do
    %{key: doc["key"], error: "each document needs a key and content"}
  end

  # Waits on everything this request queued, or found already queued.
  defp await(results, seconds) do
    pairs =
      for %{source: source, result: result} <- results, result != :unchanged do
        {source.id, source.content_hash}
      end

    states = Documents.await(pairs, seconds * 1000)

    # Title and chunk count change at the swap, so report the rows as they
    # are now, not as they were at upsert.
    fresh =
      for(%{source: source} <- results, do: source.id)
      |> Documents.reload()
      |> Map.new(&{&1.id, &1})

    Enum.map(results, fn
      %{source: source} = result ->
        %{result | source: Map.get(fresh, source.id, source)}
        |> Map.put(:status, Map.get(states, source.id, result.status))

      result ->
        result
    end)
  end

  defp result_json(%{source: source} = result) do
    %{
      key: result.key,
      id: source.id,
      result: result.result,
      status: result.status,
      title: source.title,
      content_hash: source.content_hash,
      chunk_count: source.chunk_count
    }
    |> put_unless_empty(:warnings, result.warnings)
    |> put_error(result.status, source)
  end

  defp result_json(%{key: key, error: error}), do: %{key: key, error: error}

  # A failed version's error is only known after waiting; report it then.
  defp put_error(json, "failed", source) do
    error = KB.Repo.get(KB.Sources.Source, source.id) |> then(&(&1 && &1.error))
    Map.put(json, :error, error || "indexing failed")
  end

  defp put_error(json, _status, _source), do: json

  defp count_results(results) do
    results
    |> Enum.frequencies_by(fn
      %{error: _} -> "error"
      %{result: result} -> to_string(result)
    end)
  end

  ## Reads

  defp fetch(collection, key) do
    case Documents.get(collection, key) do
      {:ok, source} -> {:ok, source}
      {:error, :not_found} -> {:error, 404, "No document at #{key} in #{collection}"}
    end
  end

  defp fetch_content(source) do
    case Documents.content(source) do
      {:ok, content, hash} ->
        {:ok, content, hash}

      {:error, :no_content} ->
        {:error, 409, "Document has not been indexed yet (status: #{source.status})"}
    end
  end

  defp maybe_section(content, nil), do: {:ok, content}
  defp maybe_section(content, ""), do: {:ok, content}

  defp maybe_section(content, heading) do
    case KB.Markdown.section(content, heading) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, 404, "No section headed #{heading}"}
    end
  end

  defp multi_json(source, content, include_content) do
    json = Documents.summary(source)

    cond do
      content == nil ->
        Map.merge(json, %{content: nil, pending: true})

      include_content ->
        Map.merge(json, %{content: content, content_hash: Documents.hash(content)})

      true ->
        json
    end
  end

  # Links are asked about by a document's key, or by a bare slug, which
  # also works for a slug no document has yet (who links to a missing page).
  defp link_subject(collection, %{"key" => key}) when is_binary(key) and key != "" do
    case Documents.get(collection, key) do
      {:ok, source} -> {:ok, source, source.slug}
      {:error, :not_found} -> {:error, 404, "No document at #{key} in #{collection}"}
    end
  end

  defp link_subject(_collection, %{"slug" => slug}) when is_binary(slug) and slug != "" do
    {:ok, nil, String.downcase(slug)}
  end

  defp link_subject(_collection, _params), do: {:error, 400, "key or slug is required"}

  ## Params

  defp selector(%{"keys" => keys}) do
    with {:ok, keys} <- require_keys(keys), do: {:ok, [keys: keys]}
  end

  defp selector(%{"prefix" => prefix}) when is_binary(prefix), do: {:ok, [prefix: prefix]}
  defp selector(_params), do: {:error, "keys or prefix is required"}

  defp parse_limit(nil), do: {:ok, 50}
  defp parse_limit(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp parse_limit(_), do: {:error, "limit must be a positive integer"}

  defp require_documents(docs) when is_list(docs) and docs != [] do
    if length(docs) > @max_batch,
      do: {:error, "at most #{@max_batch} documents per request"},
      else: {:ok, docs}
  end

  defp require_documents(_), do: {:error, "documents must be a non-empty list"}

  defp require_keys(keys) when is_list(keys) and keys != [] do
    if Enum.all?(keys, &is_binary/1),
      do: {:ok, keys},
      else: {:error, "keys must be a list of strings"}
  end

  defp require_keys(_), do: {:error, "keys must be a non-empty list"}

  defp require_string(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp require_string(_, name), do: {:error, 400, "#{name} is required"}

  defp parse_wait(%{"wait" => true} = params) do
    case params["timeout"] do
      nil -> {:ok, @default_wait_seconds}
      n when is_integer(n) and n > 0 -> {:ok, min(n, @max_wait_seconds)}
      _ -> {:error, "timeout must be a positive number of seconds"}
    end
  end

  defp parse_wait(_params), do: {:ok, nil}

  defp put_unless_empty(json, _key, []), do: json
  defp put_unless_empty(json, key, value), do: Map.put(json, key, value)

  defp json_resp(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end

defmodule KB.Search.Params do
  @moduledoc """
  Reads search parameters from a JSON-style map, for both `POST /api/search`
  and the MCP `search` tool, into the options `KB.Search.run/2` takes.

  Unknown keys are ignored. A bad value is an error rather than a silent
  default, so a typo in a filter can't widen a search unnoticed.
  """

  @modes %{
    "hybrid" => :hybrid,
    "semantic" => :semantic,
    "keyword" => :keyword,
    "fulltext" => :keyword
  }
  @groupings %{"chunk" => :chunk, "document" => :document}
  @max_limit 100

  @doc """
  Returns `{:ok, query, opts}` or `{:error, message}`. Keys may be strings
  or atoms.
  """
  def parse(params) when is_map(params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    with {:ok, query} <- query(params["query"]),
         {:ok, mode} <- choice(params["mode"], @modes, :hybrid, "mode"),
         {:ok, group_by} <- choice(params["group_by"], @groupings, :chunk, "group_by"),
         {:ok, limit} <- integer(params["limit"], 10, 1, @max_limit, "limit"),
         {:ok, offset} <- integer(params["offset"], 0, 0, 10_000, "offset"),
         {:ok, threshold} <- number(params["threshold"], 0.0, "threshold"),
         {:ok, rerank} <- boolean(params["rerank"], "rerank"),
         {:ok, full_frontmatter} <- boolean(params["full_frontmatter"], "full_frontmatter"),
         {:ok, top_n} <- integer(params["rerank_top_n"], 30, 1, 100, "rerank_top_n"),
         {:ok, budget} <-
           integer(params["latency_budget_ms"], 1_450, 500, 5_000, "latency_budget_ms"),
         {:ok, tags} <- strings(params["tags"], "tags"),
         {:ok, collection} <- strings(params["collection"], "collection"),
         {:ok, collections} <- strings(params["collections"], "collections"),
         {:ok, source_types} <- strings(params["source_type"], "source_type"),
         {:ok, key_prefix} <- string(params["key_prefix"], "key_prefix"),
         {:ok, rerank_model} <- string(params["rerank_model"], "rerank_model"),
         {:ok, frontmatter} <- object(params["frontmatter"], "frontmatter"),
         {:ok, updated_after} <- datetime(params["updated_after"], "updated_after") do
      opts =
        [
          mode: mode,
          group_by: group_by,
          limit: limit,
          offset: offset,
          threshold: threshold,
          rerank_top_n: top_n,
          latency_budget_ms: budget,
          tags: tags,
          collections: Enum.uniq(collection ++ collections),
          full_frontmatter: full_frontmatter == true,
          source_types: source_types,
          key_prefix: key_prefix,
          rerank_model: rerank_model,
          frontmatter: frontmatter,
          updated_after: updated_after
        ]
        |> then(fn opts ->
          if rerank == nil, do: opts, else: Keyword.put(opts, :rerank, rerank)
        end)

      {:ok, query, opts}
    end
  end

  defp query(q) when is_binary(q) do
    if String.trim(q) == "", do: {:error, "query field is required"}, else: {:ok, q}
  end

  defp query(_), do: {:error, "query field is required"}

  defp choice(nil, _allowed, default, _name), do: {:ok, default}

  defp choice(value, allowed, _default, name) do
    case Map.fetch(allowed, value) do
      {:ok, choice} -> {:ok, choice}
      :error -> {:error, "#{name} must be one of: #{allowed |> Map.keys() |> Enum.join(", ")}"}
    end
  end

  defp integer(nil, default, _min, _max, _name), do: {:ok, default}

  defp integer(n, _default, min, max, _name) when is_integer(n) and n >= min,
    do: {:ok, min(n, max)}

  defp integer(_, _default, min, _max, name),
    do: {:error, "#{name} must be an integer of at least #{min}"}

  defp number(nil, default, _name), do: {:ok, default}
  defp number(n, _default, _name) when is_number(n), do: {:ok, n / 1}
  defp number(_, _default, name), do: {:error, "#{name} must be a number"}

  defp boolean(nil, _name), do: {:ok, nil}
  defp boolean(b, _name) when is_boolean(b), do: {:ok, b}
  defp boolean(_, name), do: {:error, "#{name} must be true or false"}

  # One string, a comma-separated string, or a list of strings.
  defp strings(nil, _name), do: {:ok, []}

  defp strings(value, _name) when is_binary(value) do
    {:ok, value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}
  end

  defp strings(values, name) when is_list(values) do
    if Enum.all?(values, &is_binary/1),
      do: {:ok, values},
      else: {:error, "#{name} must be a string or a list of strings"}
  end

  defp strings(_, name), do: {:error, "#{name} must be a string or a list of strings"}

  defp string(nil, _name), do: {:ok, nil}
  defp string(value, _name) when is_binary(value), do: {:ok, value}
  defp string(_, name), do: {:error, "#{name} must be a string"}

  defp object(nil, _name), do: {:ok, nil}
  defp object(map, _name) when is_map(map), do: {:ok, map}
  defp object(_, name), do: {:error, "#{name} must be a JSON object"}

  defp datetime(nil, _name), do: {:ok, nil}

  defp datetime(value, name) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        {:ok, at}

      {:error, _} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
          {:error, _} -> {:error, "#{name} must be an ISO 8601 date or timestamp"}
        end
    end
  end

  defp datetime(_, name), do: {:error, "#{name} must be an ISO 8601 date or timestamp"}
end

defmodule KB.Tagger do
  @moduledoc """
  Suggests tags for a source by asking an LLM to read the start of its text.

  Only used when the caller supplied no tags of their own. The existing tag
  vocabulary is passed along so the model reuses `elixir` instead of inventing
  `elixir-lang`, which keeps tag filtering useful.

  Suggestion is best-effort: any failure returns `{:error, reason}` and
  ingestion carries on untagged rather than failing over a nicety.
  """

  @api_url "https://openrouter.ai/api/v1/chat/completions"
  @default_model "deepseek/deepseek-v4.1-flash"

  # Enough text to characterize a document without paying for a whole book.
  @excerpt_bytes 6_000
  @max_tags 5
  @timeout 30_000

  @doc """
  Returns `{:ok, tags}` with up to #{@max_tags} lowercase tags, or `{:error, reason}`.
  """
  def suggest(text, opts \\ []) do
    with {:ok, body} <- call_api(prompt(text, opts), opts) do
      parse_tags(body)
    end
  end

  @doc """
  Fills in tags for a source that has none, and returns the source.

  Never fails the caller: a source that already has tags, or a suggestion call
  that errors, comes back unchanged.
  """
  def maybe_auto_tag(source, text) do
    if source.tags in [nil, []] do
      known = KB.Sources.list_tags() |> Enum.map(& &1.tag)

      case tagger().suggest(text, title: source.title, known_tags: known) do
        {:ok, [_ | _] = tags} ->
          case KB.Sources.update_source_if_present(source, %{tags: tags}) do
            {:ok, source} -> source
            {:error, _reason} -> source
          end

        _ ->
          source
      end
    else
      source
    end
  end

  defp tagger, do: Application.get_env(:kb, :tagger, __MODULE__)

  # Swap models with `config :kb, tagger_model: "..."` (any OpenRouter id).
  defp model, do: Application.get_env(:kb, :tagger_model, @default_model)

  defp prompt(text, opts) do
    excerpt = text |> String.slice(0, @excerpt_bytes) |> String.trim()

    known =
      case opts[:known_tags] do
        [_ | _] = tags -> "Existing tags in this knowledge base: #{Enum.join(tags, ", ")}\n"
        _ -> ""
      end

    title = if t = opts[:title], do: "Title: #{t}\n", else: ""

    """
    Suggest up to #{@max_tags} topic tags for this document.

    Rules:
    - Reuse an existing tag whenever it fits; only invent one if none do.
    - Lowercase, hyphenated, one to three words each (e.g. "machine-learning").
    - Broad subjects, not specifics from the text.
    - Answer with a JSON array of strings and nothing else.

    #{known}#{title}
    Document:
    #{excerpt}
    """
  end

  defp call_api(prompt, opts) do
    api_key =
      System.get_env("OPENROUTER_API_KEY") ||
        raise "OPENROUTER_API_KEY environment variable is not set"

    req_opts =
      [
        url: @api_url,
        json: %{
          model: model(),
          messages: [%{role: "user", content: prompt}],
          temperature: 0
        },
        headers: [{"authorization", "Bearer #{api_key}"}],
        receive_timeout: @timeout
      ]
      |> put_plug(opts)

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, exception} -> {:error, {:request_failed, exception}}
    end
  end

  defp put_plug(req_opts, opts) do
    plug = opts[:plug] || Application.get_env(:kb, :tagger_req_options)[:plug]
    if plug, do: Keyword.put(req_opts, :plug, plug), else: req_opts
  end

  defp parse_tags(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    {:ok, content |> extract_json() |> normalize()}
  end

  defp parse_tags(body), do: {:error, {:unexpected_response, body}}

  # Models like to wrap the array in prose or a ```json fence, so take the
  # first bracketed run rather than trusting the whole string to be JSON.
  defp extract_json(content) do
    case Regex.run(~r/\[.*\]/s, content) do
      [json] ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp normalize(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn tag ->
      tag
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/, "-")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_tags)
  end
end

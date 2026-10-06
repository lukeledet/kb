defmodule KB.MCP.Tools.MultiGetTool do
  @moduledoc """
  Get several documents from a collection at once, by a list of keys or a key
  prefix such as concepts/, ordered by key
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Documents

  # Keeps a prefix read of a large folder from flooding the context. The
  # response says when it was cut short.
  @max_bytes 200_000

  schema do
    field :collection, :string, required: true, description: "Collection, such as wiki"
    field :keys, {:list, :string}, description: "Document keys to fetch"
    field :prefix, :string, description: "Fetch every document whose key starts with this"
    field :limit, :integer, description: "Maximum documents to return (default: 20, max: 500)"

    field :include_content, :boolean,
      description: "Include each document's text (default: true); false lists metadata only"
  end

  @impl true
  def execute(params, frame) do
    with :ok <- Documents.validate_collection(params.collection),
         {:ok, selector} <- selector(params) do
      limit = Map.get(params, :limit) || 20
      include_content = Map.get(params, :include_content) != false

      %{documents: documents, missing: missing, truncated: truncated} =
        Documents.multi_get(params.collection, [{:limit, limit} | selector])

      {entries, cut} = entries(documents, include_content)

      response =
        Jason.encode!(%{
          documents: entries,
          missing: missing,
          truncated: truncated or cut
        })

      {:reply, Response.text(Response.tool(), response), frame}
    else
      {:error, message} ->
        {:reply, Response.text(%Response{type: :tool, isError: true}, message), frame}
    end
  end

  defp selector(%{keys: keys}) when is_list(keys) and keys != [], do: {:ok, [keys: keys]}
  defp selector(%{prefix: prefix}) when is_binary(prefix), do: {:ok, [prefix: prefix]}
  defp selector(_params), do: {:error, "Pass keys or prefix"}

  # Adds documents until the reply would pass @max_bytes, then stops.
  defp entries(documents, include_content) do
    {entries, _bytes, cut} =
      Enum.reduce_while(documents, {[], 0, false}, fn {source, content}, {acc, bytes, _cut} ->
        entry = entry(source, content, include_content)
        size = byte_size(entry[:content] || "")

        if acc != [] and bytes + size > @max_bytes,
          do: {:halt, {acc, bytes, true}},
          else: {:cont, {[entry | acc], bytes + size, false}}
      end)

    {Enum.reverse(entries), cut}
  end

  defp entry(source, nil, _include_content),
    do: source |> Documents.summary() |> Map.put(:pending, true)

  defp entry(source, content, true),
    do: Documents.detail(source, content, Documents.hash(content))

  defp entry(source, _content, false), do: Documents.summary(source)
end

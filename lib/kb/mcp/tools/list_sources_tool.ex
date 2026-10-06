defmodule KB.MCP.Tools.ListSourcesTool do
  @moduledoc "List sources in the knowledge base with optional filtering"
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Sources

  schema do
    field :tags, {:list, :string}, description: "Filter by tags"

    field :status, :string,
      description: "Filter by status (pending, processing, completed, failed)"

    field :collection, :string,
      description: "Filter by collection, such as library or wiki (default: all)"

    field :limit, :integer, description: "Maximum number of results (default: 20)"
    field :offset, :integer, description: "Offset for pagination (default: 0)"
  end

  @impl true
  def execute(params, frame) do
    limit = Map.get(params, :limit) || 20
    offset = Map.get(params, :offset) || 0

    opts =
      [limit: limit, offset: offset]
      |> maybe_add(:tags, Map.get(params, :tags))
      |> maybe_add(:status, Map.get(params, :status))
      |> maybe_add(:collection, Map.get(params, :collection))

    sources = Sources.list_sources(opts)
    total = Sources.count_sources(opts)

    response =
      Jason.encode!(%{
        sources:
          Enum.map(sources, fn s ->
            %{
              id: s.id,
              title: s.title,
              url: s.url,
              source_type: s.source_type,
              tags: s.tags,
              status: s.status,
              chunk_count: s.chunk_count,
              inserted_at: s.inserted_at,
              collection: s.collection,
              key: s.key
            }
          end),
        total: total,
        has_more: offset + limit < total
      })

    {:reply, Response.text(Response.tool(), response), frame}
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, []), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end

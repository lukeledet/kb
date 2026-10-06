defmodule KB.MCP.Tools.FindRelatedTool do
  @moduledoc """
  Find sources related to a given source by vector similarity. With a
  collection, only sources in it: for a wiki page, collection library finds
  the raw sources closest to it
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :id, :string, required: true, description: "Source ID to find related sources for"
    field :limit, :integer, description: "Maximum number of related sources (default: 5)"

    field :collection, :string,
      description: "Only return sources in this collection, such as library (default: all)"
  end

  @impl true
  def execute(%{id: id} = params, frame) do
    limit = Map.get(params, :limit) || 5

    results = KB.Search.find_related(id, limit: limit, collection: Map.get(params, :collection))

    response = Jason.encode!(%{source_id: id, related: results})
    {:reply, Response.text(Response.tool(), response), frame}
  rescue
    Ecto.NoResultsError ->
      {:reply, Response.text(%Response{type: :tool, isError: true}, "Source not found: #{id}"),
       frame}

    e in RuntimeError ->
      {:reply, Response.text(%Response{type: :tool, isError: true}, e.message), frame}
  end
end

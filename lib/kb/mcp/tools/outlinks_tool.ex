defmodule KB.MCP.Tools.OutlinksTool do
  @moduledoc """
  List the [[wikilinks]] out of a page, each resolved to the page it points
  at: ok, broken (no such page), or ambiguous (several pages share the slug)
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.{Documents, Links}

  schema do
    field :collection, :string, required: true, description: "Collection, such as wiki"
    field :key, :string, required: true, description: "Key of the page, such as concepts/scrum.md"
  end

  @impl true
  def execute(%{collection: collection, key: key}, frame) do
    case Documents.get(collection, key) do
      {:ok, source} ->
        outlinks = Links.outlinks(source)

        response = %{
          collection: collection,
          key: key,
          count: length(outlinks),
          outlinks: outlinks
        }

        {:reply, Response.text(Response.tool(), Jason.encode!(response)), frame}

      {:error, :not_found} ->
        {:reply,
         Response.text(
           %Response{type: :tool, isError: true},
           "No document at #{key} in #{collection}"
         ), frame}
    end
  end
end

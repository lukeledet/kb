defmodule KB.MCP.Tools.UpdateTagsTool do
  @moduledoc "Update the tags on a source"
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Sources

  schema do
    field :id, :string, required: true, description: "Source ID"
    field :tags, {:list, :string}, required: true, description: "New tags for the source"
  end

  @impl true
  def execute(%{id: id, tags: tags}, frame) do
    case Sources.get_source(id) do
      nil ->
        {:reply, Response.text(%Response{type: :tool, isError: true}, "Source not found: #{id}"),
         frame}

      source ->
        case Sources.update_tags(source, tags) do
          {:ok, updated} ->
            response =
              Jason.encode!(%{
                id: updated.id,
                title: updated.title,
                tags: updated.tags
              })

            {:reply, Response.text(Response.tool(), response), frame}

          {:error, changeset} ->
            {:reply,
             Response.text(
               %Response{type: :tool, isError: true},
               "Failed to update tags: #{inspect(changeset.errors)}"
             ), frame}
        end
    end
  end
end

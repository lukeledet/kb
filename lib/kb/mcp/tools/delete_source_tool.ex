defmodule KB.MCP.Tools.DeleteSourceTool do
  @moduledoc "Delete a source and its chunks from the knowledge base"
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Sources

  schema do
    field :id, :string, required: true, description: "Source ID to delete"
  end

  @impl true
  def execute(%{id: id}, frame) do
    case Sources.get_source(id) do
      nil ->
        {:reply, Response.text(%Response{type: :tool, isError: true}, "Source not found: #{id}"),
         frame}

      source ->
        case Sources.delete_source(source) do
          {:ok, _} ->
            response = Jason.encode!(%{deleted: true, id: id, title: source.title})
            {:reply, Response.text(Response.tool(), response), frame}

          {:error, reason} ->
            {:reply,
             Response.text(
               %Response{type: :tool, isError: true},
               "Failed to delete source: #{inspect(reason)}"
             ), frame}
        end
    end
  end
end

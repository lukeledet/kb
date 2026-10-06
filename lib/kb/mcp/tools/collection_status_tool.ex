defmodule KB.MCP.Tools.CollectionStatusTool do
  @moduledoc """
  Show a collection's document and chunk counts, pending and failed documents,
  and when it last changed and last synced. Without a collection, list every
  collection.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Documents

  schema do
    field :collection, :string, description: "Collection, such as wiki or library"
  end

  @impl true
  def execute(params, frame) do
    case Map.get(params, :collection) do
      nil ->
        response = Jason.encode!(%{collections: Documents.list_collections()})
        {:reply, Response.text(Response.tool(), response), frame}

      collection ->
        case Documents.validate_collection(collection) do
          :ok ->
            {:reply, Response.text(Response.tool(), Jason.encode!(Documents.status(collection))),
             frame}

          {:error, message} ->
            {:reply, Response.text(%Response{type: :tool, isError: true}, message), frame}
        end
    end
  end
end

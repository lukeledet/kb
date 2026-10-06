defmodule KB.MCP.Tools.DeleteDocumentTool do
  @moduledoc "Delete a document and its chunks by collection and key"
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Documents

  schema do
    field :collection, :string, required: true, description: "Collection, such as wiki"
    field :key, :string, required: true, description: "Document key, such as concepts/scrum.md"
  end

  @impl true
  def execute(%{collection: collection, key: key}, frame) do
    case Documents.delete(collection, [key]) do
      {:ok, %{deleted: [^key]}} ->
        response = Jason.encode!(%{deleted: true, collection: collection, key: key})
        {:reply, Response.text(Response.tool(), response), frame}

      {:ok, %{not_found: [^key]}} ->
        {:reply,
         Response.text(
           %Response{type: :tool, isError: true},
           "No document at #{key} in #{collection}"
         ), frame}

      {:error, reason} ->
        {:reply,
         Response.text(
           %Response{type: :tool, isError: true},
           "Failed to delete document: #{inspect(reason)}"
         ), frame}
    end
  end
end

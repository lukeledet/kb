defmodule KB.MCP.Tools.LinkReportTool do
  @moduledoc """
  Check a collection's [[wikilinks]]: broken links (no page has the slug),
  orphan pages (nothing else links to them), and slugs shared by several pages
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :collection, :string, required: true, description: "Collection, such as wiki"
  end

  @impl true
  def execute(%{collection: collection}, frame) do
    case KB.Documents.validate_collection(collection) do
      :ok ->
        report = KB.MCP.Async.run(fn -> {:ok, KB.Links.report(collection)} end)

        case report do
          {:ok, report} ->
            {:reply, Response.text(Response.tool(), Jason.encode!(report)), frame}

          {:error, reason} ->
            {:reply,
             Response.text(
               %Response{type: :tool, isError: true},
               "Report failed: #{inspect(reason)}"
             ), frame}
        end

      {:error, message} ->
        {:reply, Response.text(%Response{type: :tool, isError: true}, message), frame}
    end
  end
end

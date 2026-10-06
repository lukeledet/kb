defmodule KB.MCP.Tools.GetChunksTool do
  @moduledoc "Get chunks for a source with pagination"
  use Anubis.Server.Component, type: :tool

  import Ecto.Query

  alias Anubis.Server.Response
  alias KB.Repo
  alias KB.Sources

  schema do
    field :source_id, :string, required: true, description: "Source ID"
    field :offset, :integer, description: "Offset for pagination (default: 0)"
    field :limit, :integer, description: "Maximum number of chunks to return (default: 20)"
  end

  @impl true
  def execute(params, frame) do
    source_id = params.source_id
    offset = Map.get(params, :offset) || 0
    limit = Map.get(params, :limit) || 20

    case Sources.get_source(source_id) do
      nil ->
        {:reply,
         Response.text(%Response{type: :tool, isError: true}, "Source not found: #{source_id}"),
         frame}

      source ->
        unless source.arcana_document_id do
          response = Jason.encode!(%{chunks: [], total: 0, has_more: false})
          {:reply, Response.text(Response.tool(), response), frame}
        else
          doc_id = source.arcana_document_id

          chunks =
            from(c in "arcana_chunks",
              where: c.document_id == type(^doc_id, :binary_id),
              order_by: c.chunk_index,
              offset: ^offset,
              limit: ^limit,
              select: %{chunk_index: c.chunk_index, text: c.text}
            )
            |> Repo.all()

          total =
            from(c in "arcana_chunks",
              where: c.document_id == type(^doc_id, :binary_id),
              select: count(c.id)
            )
            |> Repo.one()

          response =
            Jason.encode!(%{
              chunks: chunks,
              total: total,
              has_more: offset + limit < total
            })

          {:reply, Response.text(Response.tool(), response), frame}
        end
    end
  end
end

defmodule KB.MCP.Tools.GetSourceTool do
  @moduledoc "Get full details of a source by ID"
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Sources

  schema do
    field :id, :string, required: true, description: "Source ID"
  end

  @impl true
  def execute(%{id: id}, frame) do
    case Sources.get_source(id) do
      nil ->
        {:reply, Response.text(%Response{type: :tool, isError: true}, "Source not found: #{id}"),
         frame}

      source ->
        response =
          Jason.encode!(%{
            id: source.id,
            title: source.title,
            url: source.url,
            source_type: source.source_type,
            tags: source.tags,
            status: source.status,
            error: source.error,
            metadata: source.metadata,
            chunk_count: source.chunk_count,
            content_hash: source.content_hash,
            arcana_document_id: source.arcana_document_id,
            inserted_at: source.inserted_at,
            updated_at: source.updated_at,
            collection: source.collection,
            key: source.key,
            frontmatter: source.frontmatter || %{}
          })

        {:reply, Response.text(Response.tool(), response), frame}
    end
  end
end

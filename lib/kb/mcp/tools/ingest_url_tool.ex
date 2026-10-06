defmodule KB.MCP.Tools.IngestUrlTool do
  @moduledoc "Ingest a URL into the knowledge base"
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Sources

  schema do
    field :url, :string,
      required: true,
      description: "URL to ingest (must start with http:// or https://)"

    field :title, :string, description: "Title for the source (defaults to URL if not provided)"
    field :tags, {:list, :string}, description: "Tags to apply to the source"

    field :force, :boolean,
      description: "Force re-ingestion if URL already exists (default: false)"
  end

  @impl true
  def execute(params, frame) do
    url = params.url
    title = Map.get(params, :title) || url
    tags = Map.get(params, :tags) || []
    force = Map.get(params, :force) || false

    unless String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      throw(:invalid_url)
    end

    existing = Sources.find_by_url(url)

    if existing && !force do
      response =
        Jason.encode!(%{
          source_id: existing.id,
          status: existing.status,
          message: "URL already ingested. Use force: true to re-ingest."
        })

      {:reply, Response.text(Response.tool(), response), frame}
    else
      if existing && force do
        Sources.delete_source(existing)
      end

      case Sources.create_source(%{title: title, url: url, source_type: "url", tags: tags}) do
        {:ok, source} ->
          %{source_id: source.id}
          |> KB.Workers.IngestUrl.new()
          |> Oban.insert()

          response =
            Jason.encode!(%{
              source_id: source.id,
              status: "pending",
              message: "URL queued for ingestion"
            })

          {:reply, Response.text(Response.tool(), response), frame}

        {:error, changeset} ->
          {:reply,
           Response.text(
             %Response{type: :tool, isError: true},
             "Failed to create source: #{inspect(changeset.errors)}"
           ), frame}
      end
    end
  catch
    :invalid_url ->
      {:reply,
       Response.text(
         %Response{type: :tool, isError: true},
         "Invalid URL: must start with http:// or https://"
       ), frame}
  end
end

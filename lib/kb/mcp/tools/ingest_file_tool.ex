defmodule KB.MCP.Tools.IngestFileTool do
  @moduledoc "Ingest a local file (.epub or .pdf) into the knowledge base"
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Sources

  @accepted_extensions ~w(.pdf .epub)

  schema do
    field :path, :string,
      required: true,
      description: "Absolute path to the file to ingest (.epub or .pdf)"

    field :title, :string,
      description: "Title for the source (defaults to filename if not provided)"

    field :tags, {:list, :string}, description: "Tags to apply to the source"

    field :force, :boolean,
      description: "Force re-ingestion if file already exists (default: false)"
  end

  @impl true
  def execute(params, frame) do
    path = params.path
    tags = Map.get(params, :tags) || []
    force = Map.get(params, :force) || false
    title = Map.get(params, :title) || Path.basename(path)

    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext not in @accepted_extensions ->
        {:reply,
         Response.text(
           %Response{type: :tool, isError: true},
           "Unsupported file type: #{ext}. Accepted: #{Enum.join(@accepted_extensions, ", ")}"
         ), frame}

      not File.exists?(path) ->
        {:reply, Response.text(%Response{type: :tool, isError: true}, "File not found: #{path}"),
         frame}

      true ->
        ingest(path, ext, title, tags, force, frame)
    end
  end

  defp ingest(path, ext, title, tags, force, frame) do
    {:ok, content} = File.read(path)
    content_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    source_type = String.trim_leading(ext, ".")

    case handle_dedup(content_hash, force) do
      {:existing, source} ->
        response =
          Jason.encode!(%{
            source_id: source.id,
            status: source.status,
            message: "File already ingested. Use force: true to re-ingest."
          })

        {:reply, Response.text(Response.tool(), response), frame}

      :proceed ->
        case Sources.create_source(%{
               title: title,
               source_type: source_type,
               tags: tags,
               content_hash: content_hash
             }) do
          {:ok, source} ->
            temp_path = KB.Workers.IngestContent.temp_path(source.id)
            File.write!(temp_path, content)

            %{source_id: source.id, temp_path: temp_path}
            |> KB.Workers.IngestContent.new()
            |> Oban.insert()

            response =
              Jason.encode!(%{
                source_id: source.id,
                status: "pending",
                message: "File queued for ingestion"
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
  end

  defp handle_dedup(content_hash, force) do
    case Sources.find_by_content_hash(content_hash) do
      nil ->
        :proceed

      existing when force ->
        Sources.delete_source(existing)
        :proceed

      existing ->
        {:existing, existing}
    end
  end
end

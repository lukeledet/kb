defmodule KB.MCP.Tools.UpsertDocumentTool do
  @moduledoc """
  Create or replace a small document by collection and key. Markdown
  frontmatter becomes filterable metadata, and the old text stays searchable
  until the new text is indexed. For many documents, use the kb sync CLI.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Documents

  @max_bytes 1_000_000

  # The MCP transport gives up on a call after 30 seconds, and KB.MCP.Async
  # after 25, so a wait has to finish well inside both.
  @wait_ms 20_000

  schema do
    field :collection, :string, required: true, description: "Collection, such as wiki"
    field :key, :string, required: true, description: "Document key, such as concepts/scrum.md"
    field :content, :string, required: true, description: "Full document text"

    field :title, :string,
      description: "Title (default: frontmatter title, else the first # heading)"

    field :tags, {:list, :string}, description: "Tags to add to the frontmatter's own"

    field :wait, :boolean,
      description: "Wait up to 20 seconds for the text to become searchable (default: false)"
  end

  @impl true
  def execute(params, frame) do
    if byte_size(params.content) > @max_bytes do
      error("Content is over #{@max_bytes} bytes; use the kb sync CLI or the HTTP API", frame)
    else
      KB.MCP.Async.run(fn -> upsert(params) end)
      |> case do
        {:ok, response} ->
          {:reply, Response.text(Response.tool(), Jason.encode!(response)), frame}

        {:error, :timeout} ->
          error("Timed out; the document may still be indexing", frame)

        {:error, message} when is_binary(message) ->
          error(message, frame)

        {:error, reason} ->
          error("Upsert failed: #{inspect(reason)}", frame)
      end
    end
  end

  defp upsert(params) do
    opts = [title: Map.get(params, :title), tags: Map.get(params, :tags)]

    with {:ok, %{source: source, result: result, warnings: warnings}} <-
           Documents.upsert(params.collection, params.key, params.content, opts) do
      waited = Map.get(params, :wait) && result != :unchanged

      status =
        if waited,
          do:
            Documents.await([{source.id, source.content_hash}], @wait_ms) |> Map.fetch!(source.id),
          else: source.status

      # Title and chunk count change at the swap; report them as they are now.
      source = if waited, do: Documents.reload([source.id]) |> List.first(source), else: source

      {:ok,
       source
       |> Documents.summary()
       |> Map.merge(%{result: result, status: status, warnings: warnings})}
    end
  end

  defp error(message, frame) do
    {:reply, Response.text(%Response{type: :tool, isError: true}, message), frame}
  end
end

defmodule KB.MCP.Tools.GetDocumentTool do
  @moduledoc """
  Get a document's stored text byte for byte, by collection and key (such as
  wiki and concepts/scrum.md) or by source id, optionally just one section
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.{Documents, Markdown, Sources}

  # A library book can run to megabytes, far more than a tool reply should
  # carry. Past this the text is cut and marked truncated.
  @max_bytes 200_000

  schema do
    field :collection, :string, description: "Collection, such as wiki (use with key)"
    field :key, :string, description: "Document key, such as concepts/scrum.md"
    field :id, :string, description: "Source id, instead of collection and key"

    field :section, :string,
      description: "Return only the section under this heading, with its subsections"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, source} <- find(params),
         {:ok, content, hash} <- content(source),
         {:ok, text} <- section(content, Map.get(params, :section)) do
      {text, truncated} = cap(text)

      response =
        source
        |> Documents.detail(text, hash)
        |> Documents.with_context(source)
        |> Map.put(:truncated, truncated)
        |> Jason.encode!()

      {:reply, Response.text(Response.tool(), response), frame}
    else
      {:error, message} ->
        {:reply, Response.text(%Response{type: :tool, isError: true}, message), frame}
    end
  end

  defp find(%{id: id}) when is_binary(id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %Sources.Source{} = source <- Sources.get_source(id) do
      {:ok, source}
    else
      _ -> {:error, "Source not found: #{id}"}
    end
  end

  defp find(%{collection: collection, key: key}) when is_binary(collection) and is_binary(key) do
    case Documents.get(collection, key) do
      {:ok, source} -> {:ok, source}
      {:error, :not_found} -> {:error, "No document at #{key} in #{collection}"}
    end
  end

  defp find(_params), do: {:error, "Pass collection and key, or id"}

  defp content(source) do
    case Documents.content(source) do
      {:ok, content, hash} ->
        {:ok, content, hash}

      {:error, :no_content} ->
        {:error, "Document has no indexed text yet (status: #{source.status})"}
    end
  end

  defp section(content, nil), do: {:ok, content}
  defp section(content, ""), do: {:ok, content}

  defp section(content, heading) do
    case Markdown.section(content, heading) do
      {:ok, text} -> {:ok, text}
      :error -> {:error, "No section headed #{heading}"}
    end
  end

  defp cap(text) when byte_size(text) <= @max_bytes, do: {text, false}

  defp cap(text), do: {valid_prefix(binary_part(text, 0, @max_bytes)), true}

  # A byte cut can split a character. Drop the partial character, at most
  # three bytes, so the reply stays valid UTF-8.
  defp valid_prefix(bin) do
    if String.valid?(bin), do: bin, else: valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end
end

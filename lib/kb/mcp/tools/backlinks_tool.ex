defmodule KB.MCP.Tools.BacklinksTool do
  @moduledoc """
  List the documents that link to a page with [[wikilinks]], by the page's
  key or by a bare slug (which also works for a page that doesn't exist yet)
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.{Documents, Links}

  schema do
    field :collection, :string, required: true, description: "Collection, such as wiki"
    field :key, :string, description: "Key of the page linked to, such as concepts/scrum.md"
    field :slug, :string, description: "Or the slug links use, such as scrum"
  end

  @impl true
  def execute(params, frame) do
    with :ok <- Documents.validate_collection(params.collection),
         {:ok, slug} <- slug(params) do
      backlinks = Links.backlinks(params.collection, slug)

      response = %{
        collection: params.collection,
        slug: slug,
        count: length(backlinks),
        backlinks: backlinks
      }

      {:reply, Response.text(Response.tool(), Jason.encode!(response)), frame}
    else
      {:error, message} ->
        {:reply, Response.text(%Response{type: :tool, isError: true}, message), frame}
    end
  end

  defp slug(%{collection: collection, key: key}) when is_binary(key) do
    case Documents.get(collection, key) do
      {:ok, source} -> {:ok, source.slug}
      {:error, :not_found} -> {:error, "No document at #{key} in #{collection}"}
    end
  end

  defp slug(%{slug: slug}) when is_binary(slug) and slug != "", do: {:ok, String.downcase(slug)}
  defp slug(_params), do: {:error, "Pass key or slug"}
end

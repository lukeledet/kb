defmodule KB.MCP.Tools.SearchTool do
  @moduledoc """
  Search the knowledge base. Hybrid (default) fuses keyword and meaning-based
  ranking and reranks the top hits; keyword mode supports "quoted phrases",
  +required, -excluded and prefix* terms and never calls an embedding model.
  Use group_by document for one hit per document with a snippet.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :query, :string, required: true, description: "Search query text"

    field :mode, :string,
      description: "hybrid (default), semantic, or keyword (fulltext is the old name for keyword)"

    field :group_by, :string,
      description:
        "chunk (default) or document: one hit per document, with its best chunk's snippet"

    field :limit, :integer, description: "Results per page, max 100 (default: 10)"
    field :offset, :integer, description: "Results to skip, for paging (default: 0)"

    field :collection, :string,
      description:
        "Only search this collection, such as library (ingested sources) or wiki (default: all)"

    field :collections, {:list, :string},
      description: "Only search these collections; combines with collection"

    field :key_prefix, :string,
      description: "Only documents whose key starts with this, such as concepts/"

    field :tags, {:list, :string}, description: "Only sources with any of these tags"

    field :source_type, :string,
      description: "Only sources of this type: url, pdf, epub, text, transcript, markdown"

    field :frontmatter, :map,
      description:
        "Only documents whose frontmatter contains these fields, such as {\"type\": \"concept\"}"

    field :updated_after, :string,
      description: "Only sources updated after this ISO 8601 date or timestamp"

    field :rerank, :boolean,
      description: "Rerank the top hits with a cross-encoder (default: on for hybrid)"

    field :rerank_top_n, :integer, description: "How many hits to rerank (default: 30)"

    field :latency_budget_ms, :integer,
      description:
        "How long hybrid search may take, 500 to 5000 ms (default: 1450). More gives slow embedding providers time to answer instead of falling back to keyword candidates"

    field :rerank_model, :string,
      description: "Reranker model for this search only, such as cohere/rerank-4-fast"

    field :threshold, :float, description: "Minimum score for semantic mode (default: 0.0)"

    field :full_frontmatter, :boolean,
      description:
        "Return each document's whole frontmatter; by default long lists are left out and named in frontmatter_omitted"
  end

  @impl true
  def execute(params, frame) do
    # Embedding and reranking call out over the network, so this runs off
    # the shared MCP server process. See `KB.MCP.Async`.
    result =
      with {:ok, query, opts} <- KB.Search.Params.parse(params) do
        KB.MCP.Async.run(fn ->
          with {:ok, search} <- KB.Search.run(query, opts) do
            {:ok, KB.Search.Response.render(query, search)}
          end
        end)
      end

    case result do
      {:ok, response} ->
        {:reply, Response.text(Response.tool(), Jason.encode!(response)), frame}

      {:error, :timeout} ->
        error(
          "Search timed out. The embedding provider may be slow or unreachable; retry shortly.",
          frame
        )

      {:error, message} when is_binary(message) ->
        error(message, frame)

      {:error, reason} ->
        error("Search failed: #{inspect(reason)}", frame)
    end
  end

  defp error(message, frame) do
    {:reply, Response.text(%Response{type: :tool, isError: true}, message), frame}
  end
end

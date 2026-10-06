defmodule KB.Search.Response do
  @moduledoc """
  The JSON shape of a search, shared by `POST /api/search` and the MCP
  `search` tool.

  Chunk results keep every field the original API returned (`chunk_id`,
  `text`, `chunk_index`, `score`, `source`) and add `scores`,
  `heading_path`, and `snippet`. Document results carry the document's own
  fields plus its best chunk's snippet and heading path.
  """

  @source_fields [:id, :title, :url, :author, :tags, :source_type, :collection, :key, :context]

  def render(query, search) do
    %{
      query: query,
      mode: search.mode,
      group_by: search.group_by,
      total: search.total,
      offset: search.offset,
      limit: search.limit,
      results: Enum.map(search.results, &result(&1, search.group_by)),
      timings: search.timings,
      embedding_used: search.embedding_used,
      reranked: search.reranked,
      degraded: search.degraded,
      warnings: search.warnings
    }
  end

  defp result(result, :chunk) do
    %{
      chunk_id: result.id,
      text: result.text,
      chunk_index: result.chunk_index,
      score: result.score,
      scores: result.scores,
      heading_path: result.heading_path,
      snippet: result.snippet,
      source: Map.take(result.source, @source_fields)
    }
  end

  defp result(result, :document), do: result
end

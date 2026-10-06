defmodule KB.Reranker do
  @moduledoc """
  Reorders search candidates by how well each one answers the query.

  Hybrid search finds candidates by keyword and by embedding, and fusing the
  two ranks still leaves the best passage well down the list: on a 12-query
  test set the right source ranked first for 7 queries. A cross-encoder
  reranker reads the query and each passage together and put it first for
  11 or 12.

  The reranker is configured as `{module, opts}`:

      config :kb, :reranker, {KB.Reranker.OpenRouter, model: "voyageai/rerank-2.5"}

  `nil` turns reranking off. An adapter implements `c:rerank/3`.
  """

  @type result :: %{index: non_neg_integer(), score: float()}

  @doc """
  Scores `documents` against `query`. Returns one result per document it
  scored, best first, where `index` points into `documents`.
  """
  @callback rerank(query :: String.t(), documents :: [String.t()], opts :: keyword()) ::
              {:ok, [result()]} | {:error, term()}

  @doc "The configured `{module, opts}`, or `nil` when reranking is off."
  def configured, do: Application.get_env(:kb, :reranker)

  @doc "The configured model name, for reporting."
  def model do
    case configured() do
      {_module, opts} -> Keyword.get(opts, :model)
      nil -> nil
    end
  end

  @doc """
  Reranks with the configured adapter. `{:error, :disabled}` when none is
  configured.
  """
  def rerank(query, documents, opts \\ []) do
    case configured() do
      nil -> {:error, :disabled}
      {module, config} -> module.rerank(query, documents, Keyword.merge(config, opts))
    end
  end
end

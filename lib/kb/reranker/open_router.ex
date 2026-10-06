defmodule KB.Reranker.OpenRouter do
  @moduledoc """
  Reranking through OpenRouter's `/api/v1/rerank`, which fronts Cohere,
  Voyage and others behind one request shape and the KB's existing key.

  A search is waiting on the answer, so each call has a hard deadline
  (`:timeout`, default 900 ms) and no retries. Latency varies widely: on
  2026-09-29 Voyage answered the same 30-passage request in 0.18 to 1.5 s.
  A request that has not answered by `:hedge_after` (default 400 ms) is sent
  a second time and the first answer wins. At about $0.00008 a call for
  Voyage, the duplicate costs next to nothing. See `KB.Race`.

  ## Options

    * `:model` - OpenRouter model id (required), such as
      `"voyageai/rerank-2.5"` or `"cohere/rerank-4-fast"`
    * `:timeout` - milliseconds before giving up (default 900)
    * `:hedge_after` - milliseconds before sending a second request
      (default 400; `nil` for none)
    * `:plug` - a `Req` test plug
  """

  @behaviour KB.Reranker

  @url "https://openrouter.ai/api/v1/rerank"

  @impl true
  def rerank(_query, [], _opts), do: {:ok, []}

  def rerank(query, documents, opts) do
    model = Keyword.fetch!(opts, :model)
    timeout = Keyword.get(opts, :timeout, 900)
    hedge_after = Keyword.get(opts, :hedge_after, 400)
    body = %{model: model, query: query, documents: documents}

    request = fn -> post(body, timeout, opts) end

    attempts =
      if hedge_after && hedge_after < timeout,
        do: [{0, request}, {hedge_after, request}],
        else: [{0, request}]

    KB.Race.first_ok(attempts, timeout)
  end

  defp post(body, timeout, opts) do
    req_opts =
      [
        url: @url,
        json: body,
        headers: [{"authorization", "Bearer #{api_key()}"}],
        receive_timeout: timeout,
        pool_timeout: timeout,
        retry: false
      ]
      |> then(fn req_opts ->
        if plug = opts[:plug], do: Keyword.put(req_opts, :plug, plug), else: req_opts
      end)

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"results" => results}}} ->
        {:ok,
         results
         |> Enum.map(&%{index: &1["index"], score: &1["relevance_score"]})
         |> Enum.sort_by(& &1.score, :desc)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  defp api_key do
    System.get_env("OPENROUTER_API_KEY") ||
      raise "OPENROUTER_API_KEY environment variable is not set"
  end
end

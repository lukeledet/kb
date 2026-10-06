defmodule KB.Embedder.OpenAI do
  @moduledoc """
  Client for the OpenAI `/v1/embeddings` protocol.

  Both embedding backends speak it: OpenRouter's hosted endpoint and the
  llama.cpp server on the LAN. A backend supplies a config and this module
  does the request, the batching and the response parsing, so the two stay
  identical in everything but the endpoint they talk to.

  `budget` is a function of the caller's options rather than a fixed pair,
  because a query and a document get different timeouts. See
  `KB.Embedder.OpenRouter.request_budget/1`.

  A caller that is waiting on the result can pass `hedge_after: ms`. A request
  that has not answered by then is sent a second time, and whichever answers
  first wins. OpenRouter answered the same one-chunk request in 0.6 s and in
  7.3 s on consecutive tries, and a second copy usually lands on a faster
  provider. Embedding has no side effects, so a duplicate costs only tokens.
  """

  @type config :: %{
          optional(:body) => (keyword() -> map()),
          url: String.t(),
          model: String.t(),
          api_key: (-> String.t()) | nil,
          batch_size: pos_integer(),
          max_concurrency: (-> pos_integer()),
          budget: (keyword() -> {pos_integer(), non_neg_integer()})
        }

  @spec embed(config(), String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(config, text, opts) do
    case call_api(config, text, opts) do
      {:ok, %{"data" => [%{"embedding" => embedding} | _]}} ->
        {:ok, embedding}

      {:ok, body} ->
        {:error, {:unexpected_response, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec embed_batch(config(), [String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(config, texts, opts) do
    texts
    |> Enum.chunk_every(config.batch_size)
    |> Task.async_stream(&request(config, &1, opts),
      max_concurrency: config.max_concurrency.(),
      ordered: true,
      # Each request is already bounded by Req's receive_timeout; let it govern
      # rather than have async_stream kill in-flight tasks.
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, %{"data" => data}}}, {:ok, acc} ->
        embeddings =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:cont, {:ok, [embeddings | acc]}}

      {:ok, {:ok, body}}, {:ok, _acc} ->
        {:halt, {:error, {:unexpected_response, body}}}

      {:ok, {:error, reason}}, {:ok, _acc} ->
        {:halt, {:error, reason}}

      {:exit, reason}, {:ok, _acc} ->
        {:halt, {:error, {:embed_task_exit, reason}}}
    end)
    |> case do
      {:ok, batches} -> {:ok, batches |> Enum.reverse() |> Enum.concat()}
      {:error, _reason} = error -> error
    end
  end

  defp request(config, input, opts) do
    call = fn -> call_api(config, input, opts) end

    case Keyword.get(opts, :hedge_after) do
      nil -> call.()
      ms -> KB.Race.first_ok([{0, call}, {ms, call}])
    end
  end

  defp call_api(config, input, opts) do
    extra = if body = config[:body], do: body.(opts), else: %{}
    body = Map.merge(extra, %{model: config.model, input: input})
    {receive_timeout, _max_retries} = config.budget.(opts)

    req_opts =
      [url: config.url, json: body, receive_timeout: receive_timeout]
      |> put_auth(config)
      |> put_retry(config, opts)
      |> put_plug(opts)

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  defp put_auth(req_opts, %{api_key: nil}), do: req_opts

  defp put_auth(req_opts, %{api_key: api_key}) do
    Keyword.put(req_opts, :headers, [{"authorization", "Bearer #{api_key.()}"}])
  end

  # Retry transient failures (timeouts, dropped connections, 429/5xx) with
  # backoff so one slow response doesn't fail the whole document. Embeddings
  # are side-effect free, so retrying the POST is safe. Skipped under a test
  # plug to keep tests fast and deterministic.
  defp put_retry(req_opts, config, opts) do
    if opts[:plug] do
      req_opts
    else
      {_receive_timeout, max_retries} = config.budget.(opts)
      Keyword.merge(req_opts, retry: :transient, max_retries: max_retries)
    end
  end

  defp put_plug(req_opts, opts) do
    if plug = opts[:plug], do: Keyword.put(req_opts, :plug, plug), else: req_opts
  end
end

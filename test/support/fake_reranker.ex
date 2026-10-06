defmodule KB.Test.FakeReranker do
  @moduledoc """
  Stands in for `KB.Reranker.OpenRouter` in tests.

  With `prefer: word`, passages containing `word` score 1.0 and the rest
  0.0, so a test can pick which passage should win. `fail: true` returns an
  error, and `sleep: ms` answers late. Each call reports its query and
  passages to the process in `notify`, if set.
  """

  @behaviour KB.Reranker

  @impl true
  def rerank(query, documents, opts) do
    if pid = opts[:notify], do: send(pid, {:reranked, query, documents})
    if ms = opts[:sleep], do: Process.sleep(ms)

    if opts[:fail] do
      {:error, :boom}
    else
      word = opts[:prefer] || ""

      results =
        documents
        |> Enum.with_index()
        |> Enum.map(fn {text, index} ->
          %{index: index, score: if(word != "" and text =~ word, do: 1.0, else: 0.0)}
        end)
        |> Enum.sort_by(& &1.score, :desc)

      {:ok, results}
    end
  end
end

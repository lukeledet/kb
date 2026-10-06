defmodule KB.Test.FakeEmbedder do
  @behaviour Arcana.Embedder

  @impl true
  def embed(_text, _opts \\ []) do
    {:ok, make_vector()}
  end

  @impl true
  def embed_batch(texts, _opts \\ []) do
    {:ok, Enum.map(texts, fn _ -> make_vector() end)}
  end

  @impl true
  def dimensions(_opts \\ []), do: 4096

  defp make_vector do
    for i <- 1..4096, do: :math.sin(i / 100.0) * 0.01
  end
end

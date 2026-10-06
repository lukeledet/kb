defmodule KB.Test.HashEmbedder do
  @moduledoc """
  Deterministic bag-of-words vectors for search tests, so cosine similarity
  tracks the words two texts share. `KB.Test.FakeEmbedder` gives every text
  the same vector, which makes semantic ranking meaningless.
  """

  @behaviour Arcana.Embedder

  @impl true
  def embed(text, _opts \\ []), do: {:ok, vector(text)}

  @impl true
  def embed_batch(texts, _opts \\ []), do: {:ok, Enum.map(texts, &vector/1)}

  @impl true
  def dimensions(_opts \\ []), do: 4096

  def vector(text) do
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.frequencies_by(&:erlang.phash2(&1, 4096))

    # A small constant keeps an empty text from being a zero vector.
    for i <- 0..4095, do: Map.get(counts, i, 0) + 0.001
  end
end

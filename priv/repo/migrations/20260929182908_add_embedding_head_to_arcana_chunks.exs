defmodule KB.Repo.Migrations.AddEmbeddingHeadToArcanaChunks do
  use Ecto.Migration

  @moduledoc """
  Store the first 1,024 dimensions of each chunk embedding at half precision.

  Semantic search scanned every full 4,096-dimension vector, which took
  about 150 ms over 13,600 chunks. Qwen3-Embedding is trained so that a
  prefix of its vector still ranks well (Matryoshka representation), so
  search now scans this 2 KB prefix, then re-scores the best 400 with the
  full vectors. On production queries that returned the same top 30 as the
  exact scan, in about a third of the time.

  A generated column keeps it in step with `embedding` on every insert, with
  no change to Arcana's schema or to KB.Ingest. Adding it rewrites the table
  once, which blocks writes and searches for a few seconds.
  """

  def up do
    execute """
    ALTER TABLE arcana_chunks
      ADD COLUMN embedding_head halfvec(1024)
      GENERATED ALWAYS AS (subvector(embedding, 1, 1024)::halfvec(1024)) STORED
    """
  end

  def down do
    execute "ALTER TABLE arcana_chunks DROP COLUMN IF EXISTS embedding_head"
  end
end

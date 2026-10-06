defmodule KB.Repo.Migrations.AlignArcanaChunksVector4096 do
  use Ecto.Migration

  def up do
    execute "DROP INDEX IF EXISTS arcana_chunks_embedding_idx"
    execute "ALTER TABLE arcana_chunks ALTER COLUMN embedding TYPE vector(4096)"
    # pgvector HNSW/IVFFlat indexes are limited to 2000 dimensions.
    # For 4096-dim embeddings, queries use exact (sequential) search.
  end

  def down do
    execute "ALTER TABLE arcana_chunks ALTER COLUMN embedding TYPE vector(384)"

    execute """
    CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
    USING hnsw (embedding vector_cosine_ops)
    """
  end
end

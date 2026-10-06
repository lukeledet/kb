defmodule KB.Repo.Migrations.AddChunkTextTsvector do
  use Ecto.Migration

  @moduledoc """
  Precompute the fulltext vector for every chunk.

  Search used to call `to_tsvector('english', text)` on every row of
  `arcana_chunks` for each query, which parsed the whole corpus every time and
  dominated search latency. A stored generated column does that work once at
  write time, and the GIN index lets fulltext queries skip non-matching rows
  entirely.
  """

  def up do
    execute """
    ALTER TABLE arcana_chunks
      ADD COLUMN text_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('english'::regconfig, text)) STORED
    """

    execute """
    CREATE INDEX arcana_chunks_text_tsv_idx ON arcana_chunks USING GIN (text_tsv)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS arcana_chunks_text_tsv_idx"
    execute "ALTER TABLE arcana_chunks DROP COLUMN IF EXISTS text_tsv"
  end
end

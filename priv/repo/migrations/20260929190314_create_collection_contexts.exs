defmodule KB.Repo.Migrations.CreateCollectionContexts do
  use Ecto.Migration

  @moduledoc """
  Short notes that say what a collection, or a key prefix within it,
  holds, such as "one summary page per raw source" for the wiki's
  `sources/`. Search returns them with results so a caller knows what kind
  of page it found. An empty prefix is the note for the whole collection.
  """

  def change do
    create table(:collection_contexts) do
      add :collection, :string, null: false
      add :prefix, :text, null: false, default: ""
      add :description, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collection_contexts, [:collection, :prefix])
  end
end

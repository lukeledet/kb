defmodule KB.Repo.Migrations.CreateLinks do
  use Ecto.Migration

  @moduledoc """
  Wikilinks found in markdown documents: `[[slug]]`, `[[slug|alias]]`,
  `[[slug#heading]]`, and `![[embeds]]`.

  A link stores its target as a slug and is resolved when it is read, to
  whichever document in the same collection has that slug. A page created
  or renamed later then fixes the links to it without re-indexing anything.
  """

  def change do
    create table(:links) do
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :target, :text, null: false
      add :target_slug, :text, null: false
      add :heading, :text
      add :alias, :text
      add :embed, :boolean, null: false, default: false
      add :position, :integer, null: false
    end

    create index(:links, [:source_id])
    create index(:links, [:target_slug])
  end
end

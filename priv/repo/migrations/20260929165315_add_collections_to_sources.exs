defmodule KB.Repo.Migrations.AddCollectionsToSources do
  use Ecto.Migration

  @moduledoc """
  Let a source belong to a named collection and carry a stable key.

  A keyed source is a document the caller names, such as a wiki page at
  `concepts/scrum.md`, and replaces in place when its text changes. Existing
  sources have no key and land in the `library` collection.

  Content-hash dedup only makes sense for unkeyed sources. A keyed source is
  identified by its key, and two pages may legitimately hold the same text, so
  the unique index on `content_hash` now covers unkeyed rows only.
  """

  def up do
    alter table(:sources) do
      add :collection, :string, null: false, default: "library"
      add :key, :text
      add :slug, :text
      add :frontmatter, :map, null: false, default: %{}
    end

    create unique_index(:sources, [:collection, :key], where: "key IS NOT NULL")
    create index(:sources, [:collection, :slug], where: "slug IS NOT NULL")
    create index(:sources, [:frontmatter], using: "GIN")

    drop index(:sources, [:content_hash])

    create unique_index(:sources, [:content_hash],
             where: "content_hash IS NOT NULL AND key IS NULL"
           )
  end

  def down do
    drop index(:sources, [:content_hash])
    create unique_index(:sources, [:content_hash], where: "content_hash IS NOT NULL")

    drop index(:sources, [:frontmatter])
    drop index(:sources, [:collection, :slug])
    drop index(:sources, [:collection, :key])

    alter table(:sources) do
      remove :frontmatter
      remove :slug
      remove :key
      remove :collection
    end
  end
end

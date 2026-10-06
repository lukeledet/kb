defmodule KB.Repo.Migrations.CreateSources do
  use Ecto.Migration

  def change do
    create table(:sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :url, :string
      add :source_type, :string, null: false
      add :tags, {:array, :string}, default: [], null: false
      add :status, :string, null: false, default: "pending"
      add :error, :text
      add :metadata, :map, default: %{}
      add :arcana_document_id, references(:arcana_documents, type: :binary_id, on_delete: :nothing)
      add :content_hash, :string
      add :chunk_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:sources, [:tags], using: "GIN")
    create unique_index(:sources, [:url], where: "url IS NOT NULL")
    create unique_index(:sources, [:content_hash], where: "content_hash IS NOT NULL")
    create unique_index(:sources, [:arcana_document_id], where: "arcana_document_id IS NOT NULL")
    create index(:sources, [:status])
  end
end

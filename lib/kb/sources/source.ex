defmodule KB.Sources.Source do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @source_types ~w(url pdf epub text transcript markdown)
  @statuses ~w(pending processing completed failed)

  schema "sources" do
    field :title, :string
    field :url, :string
    field :source_type, :string
    field :tags, {:array, :string}, default: []
    field :status, :string, default: "pending"
    field :error, :string
    field :metadata, :map, default: %{}
    field :arcana_document_id, :binary_id
    field :content_hash, :string
    field :chunk_count, :integer, default: 0
    field :collection, :string, default: "library"
    field :key, :string
    field :slug, :string
    field :frontmatter, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [
      :title,
      :url,
      :source_type,
      :tags,
      :status,
      :error,
      :metadata,
      :arcana_document_id,
      :content_hash,
      :chunk_count,
      :collection,
      :key,
      :slug,
      :frontmatter
    ])
    |> validate_required([:title, :source_type, :collection])
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:content_hash, name: :sources_content_hash_index)
    |> unique_constraint(:key, name: :sources_collection_key_index)
  end
end

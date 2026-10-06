defmodule KB.Repo.Migrations.CreateCollections do
  use Ecto.Migration

  @moduledoc """
  Per-collection state that no single source row can hold, starting with when
  a sync last confirmed that the collection matched the caller's copy. A sync
  that changes nothing touches no source, so it can't be read off
  `sources.updated_at`.
  """

  def change do
    create table(:collections, primary_key: false) do
      add :name, :string, primary_key: true
      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end

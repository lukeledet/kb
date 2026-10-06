defmodule KB.Contexts do
  @moduledoc """
  Short notes that say what a collection, or a key prefix within it, holds.

  A search hit on `sources/2026-09-27-beads.md` means little to a caller who
  doesn't know that the wiki keeps one summary page per raw source under
  `sources/`. A note for that prefix travels with every result under it.
  A note with an empty prefix covers the whole collection.

  Results carry every note that applies, the collection's first and the
  longest prefix last.
  """

  import Ecto.Query

  alias KB.Repo

  @max_chars 500

  @doc "The notes for `collection`, by prefix."
  def list(collection) do
    Repo.all(
      from c in "collection_contexts",
        where: c.collection == ^collection,
        order_by: c.prefix,
        select: %{prefix: c.prefix, description: c.description, updated_at: c.updated_at}
    )
  end

  @doc """
  Sets the note for `prefix` in `collection`. An empty or `nil` description
  removes it.
  """
  def put(collection, prefix, description) do
    with :ok <- KB.Documents.validate_collection(collection),
         :ok <- validate_prefix(prefix) do
      case description do
        blank when blank in [nil, ""] -> delete(collection, prefix)
        text when is_binary(text) -> upsert(collection, prefix, String.trim(text))
        _ -> {:error, "description must be a string"}
      end
    end
  end

  defp upsert(collection, prefix, description) do
    if String.length(description) > @max_chars do
      {:error, "description is longer than #{@max_chars} characters"}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        "collection_contexts",
        [
          %{
            collection: collection,
            prefix: prefix,
            description: description,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: [set: [description: description, updated_at: now]],
        conflict_target: [:collection, :prefix]
      )

      {:ok, %{prefix: prefix, description: description}}
    end
  end

  defp delete(collection, prefix) do
    Repo.delete_all(
      from c in "collection_contexts", where: c.collection == ^collection and c.prefix == ^prefix
    )

    {:ok, %{prefix: prefix, description: nil}}
  end

  defp validate_prefix(prefix) when is_binary(prefix) do
    if String.starts_with?(prefix, "/"), do: {:error, "prefix must be relative"}, else: :ok
  end

  defp validate_prefix(_), do: {:error, "prefix must be a string"}

  @doc """
  Every note for `collections`, loaded once, for `for_key/3` to consult
  per result.
  """
  def load(collections) do
    Repo.all(
      from c in "collection_contexts",
        where: c.collection in ^collections,
        select: {c.collection, c.prefix, c.description}
    )
    |> Enum.group_by(&elem(&1, 0), fn {_collection, prefix, description} ->
      {prefix, description}
    end)
    |> Map.new(fn {collection, notes} ->
      {collection, Enum.sort_by(notes, fn {prefix, _} -> String.length(prefix) end)}
    end)
  end

  @doc """
  The notes that apply to `key` in `collection`, general first. A document
  without a key gets only the collection's note.
  """
  def for_key(loaded, collection, key) do
    for {prefix, description} <- Map.get(loaded, collection, []),
        prefix == "" or (key != nil and String.starts_with?(key, prefix)),
        do: description
  end
end

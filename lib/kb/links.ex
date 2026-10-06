defmodule KB.Links do
  @moduledoc """
  Wikilinks between keyed markdown documents.

  A document's links are extracted from its text (`KB.Markdown.links/1`)
  and stored when the version is swapped in (`KB.Documents`), in the same
  transaction, so the links always describe the searchable text.

  A link stores its target as a slug and is resolved when it is read: to
  every document in the same collection whose slug matches. None means the
  link is broken; more than one means the slug is ambiguous. A page created
  or renamed later fixes the links to it without anything being re-indexed.
  """

  import Ecto.Query

  alias KB.{Markdown, Repo}
  alias KB.Sources.Source

  # Link lists in a report are capped so a large collection can't produce an
  # enormous reply. Counts are always complete.
  @report_limit 500

  @doc """
  Replaces the stored links of `source` with those in `text`. Run it inside
  the transaction that swaps the text in.
  """
  def replace!(%Source{id: id}, text) do
    Repo.delete_all(from l in "links", where: l.source_id == type(^id, :binary_id))

    rows =
      for link <- Markdown.links(text) do
        %{
          source_id: Ecto.UUID.dump!(id),
          target: link.target,
          target_slug: link.slug,
          heading: link.heading,
          alias: link.alias,
          embed: link.embed,
          position: link.position
        }
      end

    rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all("links", &1))
    length(rows)
  end

  @doc """
  Re-extracts the links of every indexed markdown document in `collection`
  from its stored text, without embedding anything. For when link
  extraction changes, and to fill in documents indexed before links were
  stored. Returns the number of documents.
  """
  def relink(collection) do
    rows =
      Repo.all(
        from s in Source,
          join: d in "arcana_documents",
          on: d.id == s.arcana_document_id,
          where:
            s.collection == ^collection and not is_nil(s.key) and s.source_type == "markdown",
          select: {s, d.content}
      )

    {:ok, count} =
      Repo.transaction(fn ->
        Enum.each(rows, fn {source, content} -> replace!(source, content) end)
        length(rows)
      end)

    count
  end

  @doc """
  The documents in `collection` that link to `slug`, each with how many
  times, and the aliases and headings those links use. Ordered by key.
  """
  def backlinks(collection, slug) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT s.id, s.key, s.title, count(*),
               coalesce(array_agg(DISTINCT l.alias) FILTER (WHERE l.alias IS NOT NULL), '{}'),
               coalesce(array_agg(DISTINCT l.heading) FILTER (WHERE l.heading IS NOT NULL), '{}')
        FROM links l
        JOIN sources s ON s.id = l.source_id
        WHERE s.collection = $1 AND l.target_slug = $2
        GROUP BY s.id, s.key, s.title
        ORDER BY s.key
        """,
        [collection, slug]
      )

    for [id, key, title, count, aliases, headings] <- rows do
      %{id: uuid(id), key: key, title: title, count: count, aliases: aliases, headings: headings}
    end
  end

  @doc """
  The links out of `source`, one entry per target and heading, in the order
  they first appear, each resolved against `source`'s collection: `ok` with
  one document, `broken` with none, `ambiguous` with several.
  """
  def outlinks(%Source{} = source) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT l.target_slug, l.heading, count(*), min(l.position),
               coalesce(array_agg(DISTINCT l.alias) FILTER (WHERE l.alias IS NOT NULL), '{}'),
               coalesce(jsonb_agg(DISTINCT jsonb_build_object('id', t.id, 'key', t.key, 'title', t.title))
                          FILTER (WHERE t.id IS NOT NULL), '[]')
        FROM links l
        LEFT JOIN sources t ON t.collection = $2 AND t.slug = l.target_slug
        WHERE l.source_id = $1
        GROUP BY l.target_slug, l.heading
        ORDER BY min(l.position)
        """,
        [Ecto.UUID.dump!(source.id), source.collection]
      )

    for [slug, heading, count, _first, aliases, targets] <- rows do
      %{
        target: slug,
        heading: heading,
        count: count,
        aliases: aliases,
        status: status(targets),
        documents: Enum.sort_by(targets, & &1["key"])
      }
    end
  end

  defp status([]), do: "broken"
  defp status([_one]), do: "ok"
  defp status(_many), do: "ambiguous"

  @doc """
  Link health for `collection`:

    * `broken` - links whose slug matches no document, by linking page
    * `orphans` - documents no other document links to
    * `ambiguous` - slugs that more than one document has

  Each list holds at most #{@report_limit} entries; `counts` are complete.
  """
  def report(collection) do
    broken =
      Repo.query!(
        """
        SELECT s.key, l.target_slug, count(*)
        FROM links l
        JOIN sources s ON s.id = l.source_id
        WHERE s.collection = $1
          AND NOT EXISTS (SELECT 1 FROM sources t WHERE t.collection = $1 AND t.slug = l.target_slug)
        GROUP BY s.key, l.target_slug
        ORDER BY s.key, l.target_slug
        """,
        [collection]
      ).rows

    orphans =
      Repo.query!(
        """
        SELECT t.key, t.title
        FROM sources t
        WHERE t.collection = $1 AND t.key IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM links l JOIN sources s ON s.id = l.source_id
            WHERE s.collection = $1 AND l.target_slug = t.slug AND s.id <> t.id
          )
        ORDER BY t.key
        """,
        [collection]
      ).rows

    ambiguous =
      Repo.query!(
        """
        SELECT slug, array_agg(key ORDER BY key)
        FROM sources
        WHERE collection = $1 AND slug IS NOT NULL
        GROUP BY slug
        HAVING count(*) > 1
        ORDER BY slug
        """,
        [collection]
      ).rows

    [[documents, links]] =
      Repo.query!(
        """
        SELECT (SELECT count(*) FROM sources WHERE collection = $1 AND key IS NOT NULL),
               (SELECT count(*) FROM links l JOIN sources s ON s.id = l.source_id WHERE s.collection = $1)
        """,
        [collection]
      ).rows

    %{
      collection: collection,
      counts: %{
        documents: documents,
        links: links,
        broken: broken |> Enum.map(fn [_, _, n] -> n end) |> Enum.sum(),
        orphans: length(orphans),
        ambiguous: length(ambiguous)
      },
      broken:
        for(
          [key, slug, n] <- Enum.take(broken, @report_limit),
          do: %{key: key, target: slug, count: n}
        ),
      orphans:
        for([key, title] <- Enum.take(orphans, @report_limit), do: %{key: key, title: title}),
      ambiguous:
        for([slug, keys] <- Enum.take(ambiguous, @report_limit), do: %{slug: slug, keys: keys})
    }
  end

  defp uuid(<<_::128>> = binary), do: Ecto.UUID.cast!(binary)
end

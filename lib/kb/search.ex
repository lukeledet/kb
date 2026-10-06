defmodule KB.Search do
  @moduledoc """
  Searches chunks by keyword, by meaning, or both, and optionally groups the
  hits by document.

  ## Pipeline

  1. The query is parsed for keyword search (`KB.Search.Query`). Keyword
     candidates are fetched while the query is being embedded, so the two
     overlap.
  2. Semantic candidates come from an exact scan of chunk embeddings.
  3. Hybrid search fuses the two rankings with reciprocal rank fusion:
     each list contributes `1 / (60 + rank)`. It needs no score
     calibration between cosine similarity and keyword scores, which the
     weighted blend it replaced did badly.
  4. The top candidates are reranked by a cross-encoder (`KB.Reranker`),
     on by default for hybrid search.
  5. With `group_by: :document`, each document appears once, at the rank of
     its best chunk, with that chunk's snippet and heading path.

  ## Latency

  A hybrid search aims to answer within `latency_budget_ms` (default 1,450,
  at most 5,000). The reranker reserves 30% of it, between 450 and 1,200
  ms, and the embedding gets the rest: 1,000 ms by default, 2,100 ms for a
  3,000 ms budget. Past that deadline, or if every embedding backend fails,
  the search carries on with keyword candidates alone, still reranked, and
  says so in `degraded`. The reranker then gets whatever the budget has
  left, at least 300 ms, and a miss leaves the fused order in place, also
  noted in `degraded`. Keyword search never calls an embedding backend.

  A larger budget suits a caller that would rather wait for a better
  answer: when every embedding provider is slow, keyword candidates alone
  can't bridge a paraphrase such as "bad money drives out good" for
  Gresham's law.
  """

  alias KB.{Repo, Reranker, Sources}
  alias KB.Search.Query

  @rrf_k 60
  @min_candidates 200
  @default_budget_ms 1_450
  @rerank_min_ms 300
  @rerank_top_n 30
  @head_pool 400
  @keyword_pool 400
  @snippet_options "StartSel=<mark>, StopSel=</mark>, MaxWords=25, MinWords=12, ShortWord=3, MaxFragments=2, FragmentDelimiter=\" … \""
  @snippet_chars 320

  # A source's author: from metadata (set at ingest from the document), else
  # from a markdown page's frontmatter, where it may be a string or a list.
  @author_sql """
  COALESCE(s.metadata->>'author',
           CASE jsonb_typeof(s.frontmatter->'author')
             WHEN 'string' THEN s.frontmatter->>'author'
             WHEN 'array' THEN (SELECT string_agg(a, ', ')
                                FROM jsonb_array_elements_text(s.frontmatter->'author') a)
           END)
  """

  # Search results carry a document's frontmatter without the long lists a
  # wiki page keeps there: an analysis page lists 40 to 60 source slugs,
  # about 1,000 tokens a hit. get_document returns it whole.
  @frontmatter_max_list 5
  @frontmatter_max_chars 300

  @doc """
  Searches and returns chunk results only, as the original API did.

  Takes the same options as `run/2` and returns `{:ok, results}`.
  """
  def search(query, opts \\ []) when is_binary(query) do
    with {:ok, %{results: results}} <- run(query, Keyword.put(opts, :group_by, :chunk)) do
      {:ok, results}
    end
  end

  @doc """
  Searches and returns results with how the search went.

  ## Options

    * `:mode` - `:hybrid` (default), `:semantic`, or `:keyword`
      (`:fulltext` is the old name for `:keyword`)
    * `:group_by` - `:chunk` (default) or `:document`
    * `:limit` - results per page (default 10). Counts documents when
      grouped.
    * `:offset` - results to skip (default 0)
    * `:threshold` - minimum cosine similarity in semantic mode
      (default 0.0)
    * `:rerank` - rerank the top candidates (default: on for hybrid)
    * `:rerank_top_n` - how many to rerank (default #{@rerank_top_n})
    * `:rerank_model` - a reranker model for this search only, to compare
      models on the same candidates
    * `:latency_budget_ms` - how long a hybrid search aims to take (default
      1,450); see Latency above
    * `:tags` - sources with any of these tags
    * `:collections` - sources in any of these collections (default: all)
    * `:key_prefix` - documents whose key starts with this
    * `:source_types` - sources of any of these types
    * `:frontmatter` - documents whose frontmatter contains this map, such
      as `%{"type" => "concept"}`
    * `:updated_after` - sources updated after this `DateTime`
    * `:full_frontmatter` - return each document's whole frontmatter rather
      than leaving out long lists (named in `frontmatter_omitted`)

  Returns `{:ok, map}` with `results`, `total` (grouped: documents found
  among the candidates; chunks: results returned), `timings` in
  milliseconds (`embed_ms`, `sql_ms`, `rerank_ms`, `total_ms`),
  `embedding_used`, `reranked` (the model, or `nil`), and `degraded`, a
  list of what fell back: `"embedding_slow"`, `"embedding_unavailable"`,
  or `"rerank_unavailable"`, and `warnings`, such as a collection that
  doesn't exist.
  """
  def run(query, opts \\ []) when is_binary(query) do
    started = now()
    opts = normalize_opts(opts)

    state = %{
      started: started,
      opts: opts,
      sql_ms: 0,
      embed_ms: nil,
      rerank_ms: nil,
      degraded: [],
      embedding: nil,
      reranked: nil
    }

    {tsquery, state} = timed_sql(state, fn -> Query.build(query) end)
    state = exclude(state, tsquery.exclude)
    {warnings, state} = timed_sql(state, fn -> unknown_collections(opts.filters.collections) end)

    with {:ok, ranked, state} <- rank(query, tsquery, state) do
      {ranked, state} = maybe_rerank(query, ranked, state)
      search = respond(tsquery, ranked, warnings, state)
      KB.Search.Stats.record_search(search)
      {:ok, search}
    end
  end

  # Pages the ranked hits, fetches what the page shows, and reports how the
  # search went.
  defp respond(tsquery, ranked, warnings, %{opts: opts} = state) do
    {page, total} = paginate(ranked, opts, state)

    {details, state} =
      timed_sql(state, fn -> details(Enum.map(page, & &1.chunk_id), tsquery.rank) end)

    results =
      for(hit <- page, detail = details[hit.chunk_id], do: result(hit, detail, opts))
      |> attach_context(opts.group_by)

    %{
      results: results,
      total: if(opts.group_by == :document, do: total, else: length(results)),
      mode: opts.mode,
      group_by: opts.group_by,
      offset: opts.offset,
      limit: opts.limit,
      embedding_used: state.embedding != nil,
      reranked: state.reranked,
      degraded: Enum.reverse(state.degraded),
      warnings: warnings,
      timings: %{
        budget_ms: opts.budget_ms,
        embed_ms: state.embed_ms,
        sql_ms: state.sql_ms,
        rerank_ms: state.rerank_ms,
        total_ms: now() - state.started
      }
    }
  end

  defp normalize_opts(opts) do
    mode =
      case Keyword.get(opts, :mode, :hybrid) do
        :fulltext -> :keyword
        mode when mode in [:hybrid, :semantic, :keyword] -> mode
      end

    limit = Keyword.get(opts, :limit, 10)
    offset = Keyword.get(opts, :offset, 0)

    %{
      mode: mode,
      group_by: Keyword.get(opts, :group_by, :chunk),
      limit: limit,
      offset: offset,
      threshold: Keyword.get(opts, :threshold, 0.0) / 1,
      rerank: Keyword.get_lazy(opts, :rerank, fn -> mode == :hybrid end),
      rerank_top_n: Keyword.get(opts, :rerank_top_n, @rerank_top_n),
      rerank_model: Keyword.get(opts, :rerank_model),
      budget_ms: Keyword.get(opts, :latency_budget_ms, @default_budget_ms),
      full_frontmatter: Keyword.get(opts, :full_frontmatter, false),
      exclude_chunks: nil,
      candidates: max(@min_candidates, 4 * (offset + limit)),
      filters: %{
        tags: present(Keyword.get(opts, :tags)),
        collections: present(Keyword.get(opts, :collections)),
        key_prefix: present(Keyword.get(opts, :key_prefix)),
        source_types: present(Keyword.get(opts, :source_types)),
        frontmatter: present(Keyword.get(opts, :frontmatter)),
        updated_after: Keyword.get(opts, :updated_after),
        exclude_documents: nil
      }
    }
  end

  # The reranker is guaranteed 30% of the budget, within 450 and 1,200 ms,
  # and the embedding gets the rest as its deadline; the reranker then has
  # whatever is left. The default budget gives the embedding 1,000 ms.
  defp rerank_reserve(budget), do: (budget * 0.3) |> round() |> max(450) |> min(1_200)
  defp embed_deadline(budget), do: budget - rerank_reserve(budget)

  # An excluded term drops the chunks that contain it, and in document mode
  # the whole document: a document is not a good answer to `trifecta
  # -openclaw` because its best chunk happens not to mention OpenClaw.
  # Keyword search already excludes chunks through its match query.
  defp exclude(state, nil), do: state

  defp exclude(%{opts: %{group_by: :document}} = state, exclude) do
    put_in(state.opts.filters.exclude_documents, exclude)
  end

  defp exclude(state, exclude), do: put_in(state.opts.exclude_chunks, exclude)

  # A misspelled collection would otherwise just match nothing.
  defp unknown_collections(nil), do: []

  defp unknown_collections(names) do
    %{rows: rows} =
      Repo.query!("SELECT DISTINCT collection FROM sources WHERE collection = ANY($1)", [names])

    known = List.flatten(rows)
    for name <- names, name not in known, do: "unknown collection: #{name}"
  end

  defp present(value) when value in [nil, [], "", %{}], do: nil
  defp present(value), do: value

  ## Ranking

  # Each strategy returns hits in rank order: %{chunk_id, source_id, score,
  # scores}, plus the chunk's rank in each list it came from.

  defp rank(_query, tsquery, %{opts: %{mode: :keyword}} = state) do
    {rows, state} = timed_sql(state, fn -> keyword_candidates(tsquery, state.opts) end)
    {:ok, fuse(rows, []), state}
  end

  defp rank(query, _tsquery, %{opts: %{mode: :semantic}} = state) do
    with {:ok, embedding, state} <- embed(query, state) do
      {rows, state} =
        timed_sql(state, fn ->
          semantic_candidates(embedding, state.opts.threshold, state.opts)
        end)

      {:ok, fuse([], rows), state}
    end
  end

  defp rank(query, tsquery, %{opts: %{mode: :hybrid}} = state) do
    started = now()

    task =
      Task.Supervisor.async_nolink(KB.TaskSupervisor, fn ->
        embed_started = now()
        {embed_query(query), now() - embed_started}
      end)

    # Keyword candidates are fetched while the query embeds.
    {keyword, state} = timed_sql(state, fn -> keyword_candidates(tsquery, state.opts) end)

    wait = max(embed_deadline(state.opts.budget_ms) - (now() - started), 0)

    {embedding, embed_ms, state} =
      case Task.yield(task, wait) do
        {:ok, {{:ok, embedding}, ms}} ->
          {embedding, ms, state}

        {:ok, {{:error, _reason}, ms}} ->
          {nil, ms, degrade(state, "embedding_unavailable")}

        {:exit, _reason} ->
          {nil, now() - started, degrade(state, "embedding_unavailable")}

        nil ->
          # Left to finish on its own; see KB.Race for why it isn't killed.
          Task.ignore(task)
          {nil, now() - started, degrade(state, "embedding_slow")}
      end

    state = %{state | embed_ms: embed_ms, embedding: embedding}

    {semantic, state} =
      if embedding,
        do: timed_sql(state, fn -> semantic_candidates(embedding, -1.0, state.opts) end),
        else: {[], state}

    {:ok, fuse(keyword, semantic), state}
  end

  defp embed(query, state) do
    started = now()

    case embed_query(query) do
      {:ok, embedding} ->
        {:ok, embedding, %{state | embed_ms: now() - started, embedding: embedding}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embed_query(query) do
    Arcana.Embedder.embed(Arcana.Config.embedder(), query, intent: :query)
  end

  # Reciprocal rank fusion at chunk level. A list a chunk is missing from
  # adds nothing. Ties go to the chunk with the better single rank.
  defp fuse(keyword, semantic) do
    kw = rank_map(keyword)
    sem = rank_map(semantic)

    (keyword ++ semantic)
    |> Enum.uniq_by(& &1.chunk_id)
    |> Enum.map(fn row ->
      k = kw[row.chunk_id]
      s = sem[row.chunk_id]
      fused = rrf(k) + rrf(s)

      %{
        chunk_id: row.chunk_id,
        source_id: row.source_id,
        keyword_rank: k && elem(k, 0),
        semantic_rank: s && elem(s, 0),
        score: single_score(k, s, fused),
        scores: %{keyword: k && elem(k, 1), semantic: s && elem(s, 1), fused: fused}
      }
    end)
    |> Enum.sort_by(
      &{-&1.scores.fused, min(&1.keyword_rank || 1_000_000, &1.semantic_rank || 1_000_000)}
    )
  end

  # One-list searches keep that list's own score, which means something to a
  # caller; fused searches report the fused score.
  defp single_score({_, score}, nil, _fused), do: score
  defp single_score(nil, {_, score}, _fused), do: score
  defp single_score(_k, _s, fused), do: fused

  defp rank_map(rows) do
    rows |> Enum.with_index(1) |> Map.new(fn {row, rank} -> {row.chunk_id, {rank, row.score}} end)
  end

  defp rrf(nil), do: 0.0
  defp rrf({rank, _score}), do: 1.0 / (@rrf_k + rank)

  ## Reranking

  defp maybe_rerank(_query, hits, %{opts: %{rerank: false}} = state), do: {hits, state}
  defp maybe_rerank(_query, [], state), do: {[], state}

  defp maybe_rerank(query, hits, state) do
    if Reranker.configured() do
      rerank(query, hits, state)
    else
      {hits, state}
    end
  end

  defp rerank(query, hits, state) do
    {top, rest} = Enum.split(hits, state.opts.rerank_top_n)
    {passages, state} = timed_sql(state, fn -> passages(Enum.map(top, & &1.chunk_id)) end)
    top = Enum.filter(top, &Map.has_key?(passages, &1.chunk_id))
    started = now()

    timeout =
      max(state.opts.budget_ms - (started - state.started), @rerank_min_ms)

    rerank_opts =
      [timeout: timeout] ++ if(model = state.opts.rerank_model, do: [model: model], else: [])

    case Reranker.rerank(query, Enum.map(top, &passages[&1.chunk_id]), rerank_opts) do
      {:ok, scored} ->
        top = List.to_tuple(top)

        reranked =
          for %{index: index, score: score} <- scored, index < tuple_size(top) do
            hit = elem(top, index)
            %{hit | score: score, scores: Map.put(hit.scores, :rerank, score)}
          end

        # Anything the reranker left out keeps its fused place after the rest.
        seen = MapSet.new(reranked, & &1.chunk_id)
        unscored = top |> Tuple.to_list() |> Enum.reject(&MapSet.member?(seen, &1.chunk_id))

        state = %{
          state
          | rerank_ms: now() - started,
            reranked: state.opts.rerank_model || Reranker.model()
        }

        {reranked ++ unscored ++ rest, state}

      {:error, _reason} ->
        {hits, degrade(%{state | rerank_ms: now() - started}, "rerank_unavailable")}
    end
  end

  ## Paging and grouping

  defp paginate(hits, %{group_by: :document} = opts, state) do
    documents = group(hits, opts, state)
    {Enum.slice(documents, opts.offset, opts.limit), length(documents)}
  end

  defp paginate(hits, opts, _state), do: {Enum.slice(hits, opts.offset, opts.limit), length(hits)}

  # Reranked or single-list hits are already in final order, so a document
  # ranks where its best chunk does. Unreranked hybrid hits fuse again at
  # document level: a document whose best keyword chunk and best semantic
  # chunk differ still gets credit from both lists.
  defp group(hits, %{mode: :hybrid}, %{reranked: nil}) do
    kw = document_ranks(hits, :keyword_rank)
    sem = document_ranks(hits, :semantic_rank)

    hits
    |> Enum.uniq_by(& &1.source_id)
    |> Enum.map(fn best ->
      k = kw[best.source_id]
      s = sem[best.source_id]
      fused = rrf(k && {k, nil}) + rrf(s && {s, nil})
      %{best | score: fused, scores: Map.put(best.scores, :document, fused)}
    end)
    |> Enum.sort_by(&(-&1.score))
  end

  defp group(hits, _opts, _state), do: Enum.uniq_by(hits, & &1.source_id)

  defp document_ranks(hits, field) do
    hits
    |> Enum.filter(&Map.get(&1, field))
    |> Enum.sort_by(&Map.fetch!(&1, field))
    |> Enum.uniq_by(& &1.source_id)
    |> Enum.with_index(1)
    |> Map.new(fn {hit, rank} -> {hit.source_id, rank} end)
  end

  ## SQL

  defp keyword_candidates(%{match: nil}, _opts), do: []

  # Scores a chunk by the share of the query's IDF weight it covers, so rare
  # words decide the order. Half that again for the share its document's
  # title and author cover: in a wiki where "loop" is on every page, `loop
  # memory` should find the page named Loop memory first, and `Stephen Toub`
  # his own post. Another half when the title is exactly the query's words,
  # so the page named Gas Town beats a source whose title merely contains
  # it. Then a little ts_rank_cd for how often and how close together the
  # words appear.
  #
  # Checking every term against every matching chunk's tsvector took about
  # 300 ms for a question of common words, since it matched half the
  # corpus. So each term's chunks come from the GIN index and their weights
  # are summed; the match query (required and excluded pieces) is checked
  # the same way; titles are scored once per source (MATERIALIZED stops the
  # planner from redoing it per chunk); and only the best 400 by coverage
  # pay for ts_rank_cd. That takes 17 to 60 ms.
  defp keyword_candidates(tsquery, opts) do
    total = tsquery.terms |> Enum.map(& &1.weight) |> Enum.sum() |> max(1.0e-9)
    {where, params} = filters_sql(opts.filters, 8)

    """
    WITH terms AS MATERIALIZED (
      SELECT t.q::tsquery AS q, t.w FROM unnest($4::text[], $5::float8[]) AS t(q, w)
    ),
    hits AS (
      SELECT c.id, c.document_id, sum(terms.w) AS text_coverage
      FROM terms
      JOIN arcana_chunks c ON c.text_tsv @@ terms.q
      GROUP BY c.id, c.document_id
    ),
    src AS MATERIALIZED (
      SELECT s.id, s.arcana_document_id,
             (SELECT coalesce(sum(terms.w), 0) FROM terms
              WHERE to_tsvector('english', s.title || ' ' || coalesce(#{@author_sql}, '')) @@ terms.q)
               AS title_coverage,
             (length(to_tsvector('english', $7)) > 0
              AND strip(to_tsvector('english', s.title)) = strip(to_tsvector('english', $7)))::int
               AS title_exact
      FROM sources s
      WHERE s.arcana_document_id IS NOT NULL #{where}
    ),
    scored AS (
      SELECT h.id, src.id AS source_id,
             h.text_coverage + 0.5 * src.title_coverage + 0.5 * src.title_exact AS base
      FROM hits h
      JOIN src ON src.arcana_document_id = h.document_id
      WHERE h.id IN (SELECT c.id FROM arcana_chunks c WHERE c.text_tsv @@ $2::text::tsquery)
      ORDER BY base DESC
      LIMIT $6
    )
    SELECT sc.id, sc.source_id, sc.base + 0.1 * ts_rank_cd(c.text_tsv, $1::text::tsquery, 32) AS score
    FROM scored sc
    JOIN arcana_chunks c ON c.id = sc.id
    ORDER BY score DESC, sc.id
    LIMIT $3
    """
    |> candidate_rows(
      [
        tsquery.rank,
        tsquery.match,
        opts.candidates,
        Enum.map(tsquery.terms, & &1.tsquery),
        Enum.map(tsquery.terms, &(&1.weight / total)),
        max(@keyword_pool, 2 * opts.candidates),
        tsquery.plain
      ] ++ params
    )
  end

  # Scans the 1,024-dimension prefix of every embedding (see the
  # AddEmbeddingHeadToArcanaChunks migration), then re-scores the best
  # @head_pool with full vectors. Each distance is computed once, and the
  # threshold is applied afterwards: a threshold in the WHERE clause cost a
  # second distance calculation per chunk.
  defp semantic_candidates(embedding, threshold, opts) do
    {where, params} = filters_sql(opts.filters, 6)
    pool = max(@head_pool, 2 * opts.candidates)

    sql = """
    WITH head AS (
      SELECT c.id
      FROM arcana_chunks c
      JOIN sources s ON s.arcana_document_id = c.document_id
      WHERE ($5::text IS NULL OR NOT c.text_tsv @@ $5::text::tsquery) #{where}
      ORDER BY c.embedding_head <=> ($1::vector)::halfvec
      LIMIT $3
    )
    SELECT c.id, s.id, c.embedding <=> $2 AS distance
    FROM head h
    JOIN arcana_chunks c ON c.id = h.id
    JOIN sources s ON s.arcana_document_id = c.document_id
    ORDER BY distance
    LIMIT $4
    """

    head = embedding |> Enum.take(1024) |> Pgvector.new()

    %{rows: rows} =
      Repo.query!(sql, [
        head,
        Pgvector.new(embedding),
        pool,
        opts.candidates,
        opts.exclude_chunks | params
      ])

    for [chunk_id, source_id, distance] <- rows, 1 - distance > threshold do
      %{chunk_id: chunk_id, source_id: source_id, score: 1 - distance}
    end
  end

  defp candidate_rows(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)

    for [chunk_id, source_id, score] <- rows,
        do: %{chunk_id: chunk_id, source_id: source_id, score: score}
  end

  # Source-level filters as extra WHERE clauses, numbered from `first`.
  defp filters_sql(filters, first) do
    [
      {filters.tags, "s.tags && $N::varchar[]"},
      {filters.collections, "s.collection = ANY($N::varchar[])"},
      {filters.key_prefix && KB.Documents.like_prefix(filters.key_prefix), "s.key LIKE $N"},
      {filters.source_types, "s.source_type = ANY($N::varchar[])"},
      {filters.frontmatter, "s.frontmatter @> $N::jsonb"},
      {filters.updated_after && naive_utc(filters.updated_after), "s.updated_at > $N"},
      {filters.exclude_documents,
       "s.arcana_document_id NOT IN (SELECT x.document_id FROM arcana_chunks x WHERE x.text_tsv @@ $N::text::tsquery)"}
    ]
    |> Enum.reject(fn {value, _clause} -> is_nil(value) end)
    |> Enum.with_index(first)
    |> Enum.reduce({"", []}, fn {{value, clause}, n}, {sql, params} ->
      {sql <> " AND " <> String.replace(clause, "$N", "$#{n}"), params ++ [value]}
    end)
  end

  # sources.updated_at is a UTC timestamp without a zone.
  defp naive_utc(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp naive_utc(%NaiveDateTime{} = at), do: at

  # A chunk's text as the reranker sees it: the document title first, since
  # a library chunk carries no heading breadcrumb of its own.
  defp passages([]), do: %{}

  defp passages(chunk_ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.id, s.title, c.text
        FROM arcana_chunks c
        JOIN sources s ON s.arcana_document_id = c.document_id
        WHERE c.id = ANY($1)
        """,
        [chunk_ids]
      )

    Map.new(rows, fn [id, title, text] ->
      {id, String.slice("Title: #{title}\n#{text}", 0, 4000)}
    end)
  end

  # Everything a result shows, for one page of chunks. The snippet is
  # ts_headline over the chunk without its breadcrumb line.
  defp details([], _tsquery), do: %{}

  defp details(chunk_ids, tsquery) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.id, c.document_id, c.text, c.chunk_index, c.metadata->'heading_path',
               s.id, s.title, s.url, s.source_type, s.tags, s.collection, s.key,
               s.frontmatter, s.updated_at, #{@author_sql},
               b.body,
               CASE WHEN $2::text::tsquery IS NULL THEN NULL
                    ELSE ts_headline('english', b.body, $2::text::tsquery, $3) END
        FROM arcana_chunks c
        JOIN sources s ON s.arcana_document_id = c.document_id
        CROSS JOIN LATERAL (
          SELECT CASE
                   WHEN jsonb_typeof(c.metadata->'heading_path') = 'array'
                    AND split_part(c.text, E'\\n', 1) = array_to_string(
                          ARRAY(SELECT jsonb_array_elements_text(c.metadata->'heading_path')), ' > ')
                   THEN substr(c.text, length(split_part(c.text, E'\\n', 1)) + 1)
                   ELSE c.text
                 END AS body
        ) b
        WHERE c.id = ANY($1)
        """,
        [chunk_ids, tsquery, @snippet_options]
      )

    Map.new(rows, fn [
                       id,
                       doc_id,
                       text,
                       index,
                       path,
                       sid,
                       title,
                       url,
                       type,
                       tags,
                       collection,
                       key,
                       fm,
                       updated,
                       author,
                       body,
                       headline
                     ] ->
      {id,
       %{
         document_id: doc_id,
         text: text,
         chunk_index: index,
         heading_path: path || [],
         snippet: snippet(headline || body),
         source: %{
           id: uuid(sid),
           title: title,
           url: url,
           author: author,
           source_type: type,
           tags: tags,
           collection: collection,
           key: key,
           frontmatter: fm || %{},
           updated_at: updated && DateTime.from_naive!(updated, "Etc/UTC")
         }
       }}
    end)
  end

  defp snippet(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) <= @snippet_chars do
      text
    else
      cut = String.slice(text, 0, @snippet_chars)
      String.replace(cut, ~r/\s+\S*$/u, "") <> " …"
    end
  end

  defp result(hit, detail, %{group_by: :chunk}) do
    %{
      id: uuid(hit.chunk_id),
      text: detail.text,
      chunk_index: detail.chunk_index,
      document_id: uuid(detail.document_id),
      score: hit.score,
      scores: hit.scores,
      heading_path: detail.heading_path,
      snippet: detail.snippet,
      source: detail.source
    }
  end

  defp result(hit, detail, %{group_by: :document} = opts) do
    source = detail.source

    {frontmatter, omitted} =
      if opts.full_frontmatter, do: {source.frontmatter, []}, else: compact(source.frontmatter)

    %{
      id: source.id,
      collection: source.collection,
      key: source.key,
      title: source.title,
      url: source.url,
      author: source.author,
      source_type: source.source_type,
      tags: source.tags,
      frontmatter: frontmatter,
      updated_at: source.updated_at,
      heading_path: detail.heading_path,
      snippet: detail.snippet,
      score: hit.score,
      scores: hit.scores,
      chunk_id: uuid(hit.chunk_id),
      chunk_index: detail.chunk_index
    }
    |> then(fn result ->
      if omitted == [], do: result, else: Map.put(result, :frontmatter_omitted, omitted)
    end)
  end

  # Context notes (KB.Contexts) for each result's collection and key, on the
  # result itself when grouped and on its source otherwise.
  defp attach_context([], _group_by), do: []

  defp attach_context(results, group_by) do
    source = fn result -> if group_by == :document, do: result, else: result.source end
    loaded = results |> Enum.map(&source.(&1).collection) |> Enum.uniq() |> KB.Contexts.load()

    Enum.map(results, fn result ->
      %{collection: collection, key: key} = source.(result)

      case {KB.Contexts.for_key(loaded, collection, key), group_by} do
        {[], _} -> result
        {notes, :document} -> Map.put(result, :context, notes)
        {notes, :chunk} -> %{result | source: Map.put(result.source, :context, notes)}
      end
    end)
  end

  # Keeps short scalars and short lists of scalars; names what it dropped.
  defp compact(frontmatter) do
    {kept, dropped} = Enum.split_with(frontmatter, fn {_key, value} -> small?(value) end)
    {Map.new(kept), dropped |> Enum.map(&elem(&1, 0)) |> Enum.sort()}
  end

  defp small?(value) when is_binary(value), do: String.length(value) <= @frontmatter_max_chars

  defp small?(value) when is_list(value),
    do: length(value) <= @frontmatter_max_list and Enum.all?(value, &small?/1)

  defp small?(value) when is_map(value), do: false
  defp small?(_scalar), do: true

  ## Bookkeeping

  defp timed_sql(state, fun) do
    started = now()
    result = fun.()
    {result, %{state | sql_ms: state.sql_ms + now() - started}}
  end

  defp degrade(state, reason), do: %{state | degraded: [reason | state.degraded]}

  defp now, do: System.monotonic_time(:millisecond)

  defp uuid(<<_::128>> = binary), do: Ecto.UUID.cast!(binary)
  defp uuid(string) when is_binary(string), do: string

  ## Related sources

  @doc """
  Find sources related to the given source by vector similarity.

  Computes the centroid of the source's chunk embeddings, then searches
  for similar chunks excluding the source itself. Groups by source and
  ranks by average similarity.

  `collection: "library"` limits the results to one collection: for a wiki
  page, the raw sources closest to it, which is how to find citations the
  page is missing.
  """
  def find_related(source_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    collection = Keyword.get(opts, :collection)
    source = Sources.get_source!(source_id)

    unless source.arcana_document_id do
      raise "Source has no chunks"
    end

    centroid_sql = """
    SELECT AVG(embedding) AS centroid
    FROM arcana_chunks
    WHERE document_id = $1::uuid
    """

    {:ok, doc_id_bin} = Ecto.UUID.dump(source.arcana_document_id)
    %{rows: [[centroid]]} = Repo.query!(centroid_sql, [doc_id_bin])

    unless centroid do
      raise "Source has no chunks"
    end

    related_sql = """
    SELECT
      c.id AS chunk_id,
      c.text,
      c.chunk_index,
      c.document_id,
      1 - (c.embedding <=> $1) AS score,
      s.id AS source_id,
      s.title,
      s.source_type,
      s.tags,
      s.url,
      s.collection,
      s.key
    FROM arcana_chunks c
    JOIN arcana_documents d ON c.document_id = d.id
    JOIN sources s ON s.arcana_document_id = d.id
    WHERE c.document_id != $2::uuid
      AND ($4::varchar IS NULL OR s.collection = $4)
    ORDER BY c.embedding <=> $1
    LIMIT $3
    """

    fetch_limit = limit * 10

    %{rows: rows} = Repo.query!(related_sql, [centroid, doc_id_bin, fetch_limit, collection])

    rows
    |> Enum.group_by(fn [_, _, _, _, _, source_id | _] -> source_id end)
    |> Enum.map(fn {sid, chunks} ->
      scores = Enum.map(chunks, fn [_, _, _, _, score | _] -> score end)
      avg_score = Enum.sum(scores) / length(scores)
      top_chunk = Enum.max_by(chunks, fn [_, _, _, _, score | _] -> score end)
      [_, text, _, _, _, _, title, source_type, tags, url, collection, key] = top_chunk

      %{
        source_id: format_uuid(sid),
        title: title,
        source_type: source_type,
        tags: tags,
        url: url,
        collection: collection,
        key: key,
        avg_similarity: Float.round(avg_score, 4),
        top_chunk_text: text
      }
    end)
    |> Enum.sort_by(& &1.avg_similarity, :desc)
    |> Enum.take(limit)
  end

  defp format_uuid(binary) when is_binary(binary) and byte_size(binary) == 16 do
    Ecto.UUID.cast!(binary)
  end

  defp format_uuid(string) when is_binary(string), do: string
end

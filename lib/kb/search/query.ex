defmodule KB.Search.Query do
  @moduledoc """
  Turns a search box query into Postgres full-text queries.

  The syntax is the usual web-search one:

    * `word` - optional. A chunk matches if it has any optional word, and
      ranks higher the more it has.
    * `"a phrase"` - required, words adjacent and in order.
    * `+word` - required.
    * `-word` or `-"a phrase"` - excluded.
    * `word*` - matches any word starting with `word`. Takes `+` or `-` too.

  `plainto_tsquery` required every word, so a normal question such as "why
  do agent pull requests get rejected by maintainers" matched nothing.
  Every piece here goes through Postgres's English configuration, so
  stopwords drop out and words are stemmed the same way the chunks were.

  Two queries come out. `match` decides which chunks qualify: the required
  pieces if there are any, otherwise any optional word, and never an
  excluded piece. `rank` is every positive piece OR'd together, for
  `ts_rank_cd` and snippet highlighting. `exclude` is the excluded pieces
  OR'd, so a caller can drop whole documents that contain one, and `plain`
  is the positive words with the syntax taken out, for comparing with a
  title.

  Postgres ranking ignores how rare a word is, so "get" counted as much as
  "rejected" and keyword search found the right source first for 2 of 12
  test questions. Each positive piece therefore also comes out as a `term`
  with an inverse document frequency weight, counted per query through the
  full-text index (about 2 ms per word), for `KB.Search` to score coverage.
  """

  alias KB.Repo

  @type piece :: %{
          need: :optional | :required | :excluded,
          kind: :word | :phrase | :prefix,
          text: String.t()
        }
  @type term_weight :: %{tsquery: String.t(), weight: float()}
  @type t :: %{
          match: String.t() | nil,
          rank: String.t() | nil,
          exclude: String.t() | nil,
          plain: String.t(),
          terms: [term_weight()]
        }

  @token ~r/([+-]?)(?:"([^"]*)"?|(\S+))/u

  @doc """
  Splits `query` into pieces. Quotes left open run to the end of the query.
  """
  @spec parse(String.t()) :: [piece()]
  def parse(query) do
    @token
    |> Regex.scan(query, capture: :all_but_first)
    |> Enum.flat_map(&piece/1)
  end

  defp piece([sign, phrase]), do: piece([sign, phrase, ""])

  defp piece([sign, phrase, ""]) when phrase != "" do
    [%{need: need(sign, :required), kind: :phrase, text: phrase}]
  end

  defp piece([sign, "", word]) when word != "" do
    {kind, word} =
      if String.ends_with?(word, "*"),
        do: {:prefix, String.trim_trailing(word, "*")},
        else: {:word, word}

    [%{need: need(sign, :optional), kind: kind, text: word}]
  end

  defp piece(_empty), do: []

  defp need("+", _default), do: :required
  defp need("-", _default), do: :excluded
  defp need("", default), do: default

  @doc """
  Builds the `match` and `rank` tsquery texts for `query`, normalized by
  Postgres. Either is `nil` when the query has nothing to search for, such
  as a query of only stopwords.
  """
  @spec build(String.t()) :: t()
  def build(query) do
    pieces = parse(query)
    {normalized, total} = normalize(pieces)

    kept =
      pieces
      |> Enum.zip(normalized)
      |> Enum.reject(fn {_piece, {tsquery, _df}} -> tsquery in [nil, ""] end)
      |> Enum.map(fn {piece, {tsquery, df}} -> {piece.need, "(" <> tsquery <> ")", df} end)

    optional = for {:optional, q, _} <- kept, do: q
    required = for {:required, q, _} <- kept, do: q
    excluded = for {:excluded, q, _} <- kept, do: "!" <> q

    positive = if required != [], do: Enum.join(required, " & "), else: join_or(optional)

    match =
      case {positive, excluded} do
        {nil, _} -> nil
        {positive, []} -> positive
        {positive, excluded} -> "(" <> positive <> ") & " <> Enum.join(excluded, " & ")
      end

    terms =
      for {need, q, df} <- kept, need != :excluded, uniq: true do
        %{tsquery: q, weight: idf(df, total)}
      end

    plain =
      pieces
      |> Enum.reject(&(&1.need == :excluded))
      |> Enum.map_join(" ", & &1.text)

    %{
      match: match,
      rank: join_or(required ++ optional),
      exclude: join_or(for {:excluded, q, _} <- kept, do: q),
      plain: plain,
      terms: terms
    }
  end

  # BM25's inverse document frequency, which stays positive however common a
  # word is.
  defp idf(df, total), do: :math.log(1 + (total - df + 0.5) / (df + 0.5))

  defp join_or([]), do: nil
  defp join_or(queries), do: Enum.join(queries, " | ")

  # One round trip normalizes every piece and counts the chunks it matches.
  # A prefix is reduced to letters and digits first, since it is spliced into
  # to_tsquery syntax. The chunk total comes from the planner's estimate,
  # which is plenty for a weight, and never falls below the largest count.
  defp normalize([]), do: {[], 1}

  defp normalize(pieces) do
    {kinds, texts} =
      pieces
      |> Enum.map(fn
        %{kind: :prefix, text: text} -> {"prefix", String.replace(text, ~r/[^\p{L}\p{N}]/u, "")}
        %{kind: kind, text: text} -> {to_string(kind), text}
      end)
      |> Enum.unzip()

    %{rows: rows} =
      Repo.query!(
        """
        SELECT n.q,
               CASE WHEN n.q = '' THEN 0
                    ELSE (SELECT count(*) FROM arcana_chunks c WHERE c.text_tsv @@ n.q::tsquery) END,
               (SELECT reltuples::bigint FROM pg_class WHERE relname = 'arcana_chunks')
        FROM (
          SELECT p.n,
                 CASE p.kind
                   WHEN 'phrase' THEN phraseto_tsquery('english', p.text)::text
                   WHEN 'prefix' THEN CASE WHEN p.text = '' THEN ''
                                      ELSE to_tsquery('english', quote_literal(p.text) || ':*')::text END
                   ELSE plainto_tsquery('english', p.text)::text
                 END AS q
          FROM unnest($1::text[], $2::text[]) WITH ORDINALITY AS p(kind, text, n)
        ) n
        ORDER BY n.n
        """,
        [kinds, texts]
      )

    normalized = Enum.map(rows, fn [tsquery, df, _estimate] -> {tsquery, df} end)
    [[_, _, estimate] | _] = rows
    total = Enum.max([estimate || 0, 1 | Enum.map(normalized, &elem(&1, 1))])
    {normalized, total}
  end
end

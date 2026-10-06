# Search & Retrieval

## Overview

Search finds chunks by keyword, by meaning, or both, reranks the best
candidates with a cross-encoder, and can return one result per document.
The same search runs behind `POST /api/search`, the MCP `search_tool`, and
`kb search`, with one parameter parser (`KB.Search.Params`) and one response
shape (`KB.Search.Response`). The engine is `KB.Search.run/2`.

## Modes

| Mode | Candidates | Reranked by default | Calls an embedding model |
|---|---|---|---|
| `hybrid` (default) | Keyword and semantic, fused | Yes | Yes |
| `semantic` | Semantic | No | Yes |
| `keyword` | Keyword | No | Never |

`fulltext` is accepted as the old name for `keyword`. Any mode can be
reranked with `rerank: true`, or not with `rerank: false`.

## Keyword search

`KB.Search.Query` turns the query into Postgres full-text queries, using the
English configuration the chunks were indexed with, so words are stemmed and
stopwords dropped.

| Syntax | Meaning |
|---|---|
| `word` | Optional. A chunk qualifies if it has any optional word. |
| `"a phrase"` | Required, words adjacent and in order. |
| `+word` | Required. |
| `-word`, `-"a phrase"` | Excluded: drops chunks that contain it, and in document mode whole documents that contain it anywhere. Applies to semantic hits too. |
| `word*` | Prefix. Takes `+` or `-` too. |

A query made only of stopwords returns no keyword results.

Scoring. Postgres ranking ignores how rare a word is, so "get" counted as
much as "rejected". Each positive term gets a BM25 inverse document frequency
weight, counted per query through the GIN index (about 2 ms a word). A chunk
scores:

- the share of the query's weight its text covers,
- plus half the share its document's title and author cover, so `loop
  memory` finds the page named Loop memory in a wiki where "loop" is
  everywhere, and `Stephen Toub` his own post,
- plus a half when the title is exactly the query's words, so the page
  named Gas Town beats a source whose title contains it,
- plus a tenth of `ts_rank_cd`, for how often and how close together the
  words appear.

The SQL finds each term's chunks through the GIN index and sums their
weights, checks the match query the same way, scores titles once per source,
and runs `ts_rank_cd` only on the best 400. On production it takes 17 to 60
ms.

## Semantic search

The query is embedded (see [Query embedding](#query-embedding)). Chunks are
found by cosine distance over `arcana_chunks.embedding_head`, a stored
`halfvec(1024)` of each embedding's first 1,024 dimensions, and the best 400
are re-scored with the full 4,096-dimension vectors. Qwen3-Embedding is
trained so that a prefix of its vector still ranks well. On production
queries this returned the same top 30 as an exact scan, in 53 ms against
104 ms. There is still no ANN index; at 13,600 chunks none is needed.

## Hybrid search

1. Keyword candidates are fetched while the query embeds.
2. The embedding has a deadline set by `latency_budget_ms` (see
   [Latency budget](#latency-budget)): 1,000 ms by default. If it misses
   that, or every embedding backend fails, the search carries on with
   keyword candidates alone and reports `embedding_slow` or
   `embedding_unavailable` in `degraded`. Reranking still runs.
3. Semantic candidates are fetched with the embedding.
4. The two rankings are fused with reciprocal rank fusion: each list adds
   `1 / (60 + rank)`. Fusion needs no calibration between cosine similarity
   and keyword scores, which the old blend got wrong.

The weighted blend fusion replaced (half cosine similarity, half min-max
normalized `ts_rank`) was removed after phase 2 QA.

## Reranking

`KB.Reranker` is a behaviour with one adapter, `KB.Reranker.OpenRouter`,
which calls OpenRouter's `/api/v1/rerank`. The model is set in config:

```elixir
config :kb, :reranker, {KB.Reranker.OpenRouter, model: "voyageai/rerank-2.5"}
```

`nil` turns reranking off. `rerank_model` overrides the model for one
search, to compare models on the same candidates.

- The top `rerank_top_n` (default 30) fused chunks are sent as
  `Title: <document title>` followed by the chunk text, which for a wiki
  chunk starts with its heading breadcrumb.
- The reranker gets what is left of the latency budget, at least 300 ms,
  with no retries. A request that hasn't answered in 400 ms is sent a
  second time; see `KB.Race`.
- A miss leaves the fused order in place and reports `rerank_unavailable`.
- Chunks are reranked first, then grouped by document.

## Latency budget

`latency_budget_ms` (default 1,450, allowed 500 to 5,000) is how long a
hybrid search aims to take. The reranker is guaranteed 30% of it, between
450 and 1,200 ms, so the query embedding's deadline is the rest. The
reranker then gets whatever the budget has left, at least 300 ms.

| Budget | Embedding deadline |
|---|---|
| 1,450 (default) | 1,000 |
| 3,000 | 2,100 |
| 5,000 | 3,800 |

The budget exists because embedding providers have hours when every one of
them takes over a second. With the default, those searches fall back to
keyword candidates, which can't bridge a paraphrase ("bad money drives out
good" for Gresham's law). A caller that would rather wait for a better
answer, such as the research wiki's workflow at 3,000 ms, passes a larger
budget; interactive callers keep the default. `timings.budget_ms` echoes it.

## Grouping and paging

`group_by: "document"` returns each document once, where its best chunk
ranks, with that chunk's heading path and snippet. Without reranking, hybrid
results fuse again at document level, so a document whose best keyword chunk
and best semantic chunk differ gets credit from both lists.

`limit` (default 10, max 100) and `offset` page through results, counting
documents when grouped. `total` is the number of documents found among the
candidates (at least 200 chunks from each ranking) when grouped, and the
number of results returned for chunk results, as before.

## Filters

| Parameter | Matches |
|---|---|
| `collection` | Sources in this collection, or any of a list (default: all) |
| `key_prefix` | Documents whose key starts with this |
| `tags` | Sources with any of these tags |
| `source_type` | Sources of this type, or any of a list |
| `frontmatter` | Documents whose frontmatter contains this object, such as `{"type": "concept"}` |
| `updated_after` | Sources updated after this ISO 8601 date or timestamp |
| `threshold` | Semantic mode only: minimum cosine similarity |

`collection` takes a string or a list, and `collections` a list; they
combine. A collection that doesn't exist is named in `warnings`, since a
misspelling would otherwise just match nothing. A bad value is an error
(400 over HTTP), not a silent default, and so is an empty or
whitespace-only query.

## Response

```json
{
  "query": "loop memory",
  "mode": "hybrid",
  "group_by": "document",
  "total": 104,
  "offset": 0,
  "limit": 10,
  "results": [],
  "timings": {"embed_ms": 231, "sql_ms": 88, "rerank_ms": 241, "total_ms": 561},
  "embedding_used": true,
  "reranked": "voyageai/rerank-2.5",
  "degraded": [],
  "warnings": []
}
```

`timings.embed_ms` is null when nothing was embedded, and `rerank_ms` when
nothing was reranked. `degraded` lists what fell back: `embedding_slow`,
`embedding_unavailable`, or `rerank_unavailable`.

A document result's `frontmatter` leaves out long values, since an analysis
page can list 40 to 60 source slugs, about 1,000 tokens a hit. It keeps
scalars up to 300 characters and lists of up to 5 of them, and names what it
dropped in `frontmatter_omitted`. `full_frontmatter: true` returns it whole,
and `get_document` always does. `author` comes from the source's metadata,
or from the frontmatter for a markdown page. `context` holds the collection
and prefix notes that apply (see [Keyed Documents](documents.md#context-notes)).

A document result:

```json
{
  "id": "…source id…",
  "collection": "wiki",
  "key": "concepts/loop-memory.md",
  "title": "Loop memory",
  "url": null,
  "author": null,
  "source_type": "markdown",
  "tags": ["loop-engineering", "memory"],
  "frontmatter": {"type": "concept"},
  "updated_at": "2026-09-29T17:48:13Z",
  "heading_path": ["Loop memory"],
  "snippet": "<mark>Loop</mark> <mark>memory</mark> State that lives on disk …",
  "score": 0.891,
  "scores": {"keyword": 1.2, "semantic": 0.71, "fused": 0.032, "rerank": 0.891},
  "chunk_id": "…",
  "chunk_index": 0
}
```

A chunk result keeps every field the original API returned (`chunk_id`,
`text`, `chunk_index`, `score`, and `source` with `id`, `title`, `url`,
`author`, `tags`, `source_type`) and adds `scores`, `heading_path`,
`snippet`, and `collection` and `key` on `source`.

`score` is the rerank score when reranked, the fused score for unreranked
hybrid, and the keyword or cosine score for a single-list mode. `scores`
holds every component that applied. Snippets are about 300 characters from
`ts_headline`, over the chunk without its breadcrumb line, with matches
wrapped in `<mark>` and `</mark>`, since `**` already means bold in the wiki.

## Query embedding

A query goes at once to the LAN embedder and to two OpenRouter providers,
each pinned (`provider: nebius`, `provider: deepinfra`, no fallback), plus
one unpinned OpenRouter request if none has answered in 500 ms. The first
answer wins, and losing requests finish on their own. Provider latency
swings by the hour: on 2026-09-29 each provider had stretches of 0.2 s and
stretches of 2 to 20 s. The LAN embedder takes 0.65 to 1.4 s for a query it
hasn't seen.

The last 1,000 query embeddings are cached (`KB.Embedder.QueryCache`), so a
repeated query skips all of that.

## Measured on production (2026-09-29)

On the 12-query library set, grouped by document, `collection: library`:

| Setup | MRR | hit@1 | hit@3 |
|---|---|---|---|
| Weighted blend, no rerank (before) | 0.63 | 7/12 | 7/12 |
| Keyword | 0.79 | 8/12 | 11/12 |
| Hybrid, no rerank | 0.85 | 9/12 | 12/12 |
| Hybrid + Voyage rerank | 0.90 | 10/12 | 12/12 |

Latency, hybrid with rerank: median 0.35 s and p95 0.43 s with a cached
query embedding; median 0.55 to 1.2 s and p95 up to 1.46 s uncached,
depending on how the embedding providers are doing. Keyword: median 87 ms,
p95 142 ms.

`kb search` takes the common options as flags: `--collection` (comma
separated for several), `--documents`, `--prefix`, `--tags`, `--type`,
`--frontmatter '<json>'`, `--since <date>`, `--limit`, `--offset`,
`--mode`, `--no-rerank`, and `--budget <ms>`. It prints any `warnings`.

## Search health

`GET /api/stats` and the MCP stats tool include a `search` section computed
from the last 500 searches and embedding attempts, held in memory by
`KB.Search.Stats` and reset on restart:

- `searches`, `by_mode`, `degraded_share`, `degraded_by_reason`
- `total_ms`, `embed_ms`, `rerank_ms`: p50 and p95
- `query_embedding.winners`: which backend answered first (`nebius`,
  `deepinfra`, `local`, `openrouter` for the hedge, or `cache`)
- `query_embedding.backends`: each backend's attempts, errors, and p50 and
  p95 of its successful calls, win or lose

## Find related

`find_related` averages a source's chunk embeddings into a centroid, finds
the chunks nearest to it outside the source, groups them by source, and
ranks sources by average similarity. With a `collection` it returns only
sources in that collection: for a wiki page, `collection: library` finds
the raw sources closest to it, which is how to spot citations a page is
missing. Over HTTP it is `GET /api/sources/:id/related`.

# Decision: keep 4096-dim exact search, no pgvector ANN index yet

- **Date:** 2026-07-23
- **Status:** Decided (revisit at trigger below)
- **Evaluated by:** Claude Fable 5 (`claude-fable-5`, xhigh reasoning effort), approved by the repo owner

## Context

The KB embeds chunks with `qwen/qwen3-embedding-8b` at 4096 dims via OpenRouter
(`lib/kb/embedder/open_router.ex`, `config :arcana, vector_dimensions: 4096`,
column `vector(4096)`). pgvector's HNSW and IVFFlat indexes cap at 2000 dims,
so every semantic search is an exact sequential scan. The question was whether
to reduce dimensions (Matryoshka truncation or a model switch) to enable an
HNSW index.

## Measurements (live homelab instance, 2026-07-23)

- Corpus: **10 sources, 524 chunks** (408 from a single EPUB).
- MCP `search_tool` latency, 5 runs each:
  - fulltext: ~120 ms median (no embedding call)
  - semantic: ~400 ms median (min 278 ms, one 3.5 s outlier)
  - hybrid: ~540 ms median
- The fulltext-vs-semantic gap is the OpenRouter query-embedding call — the
  dominant and most variable cost. An ANN index cannot reduce it.
- The exact 4096-dim scan costs roughly 1 ms per 500 chunks.

## Decision

**Do nothing.** At this corpus size the exact scan is a rounding error next to
the query-embedding API call, and exact search gives 100% recall with zero
tuning, zero re-embed cost, and zero downtime.

## Trigger to revisit

**~20–50k chunks** (≈50–100 more books at ~400 chunks/EPUB), when the exact
scan approaches the embedding call's ~100+ ms floor. Check corpus size with
the `stats` MCP tool.

## Verified migration path (for when triggered)

Probed OpenRouter `/embeddings` directly on 2026-07-23:

- `qwen/qwen3-embedding-8b` honors `dimensions: 1536` and returns a true
  1536-dim Matryoshka vector (default remains 4096).
- `google/gemini-embedding-2` also honors `dimensions: 1536`.

Plan: keep Qwen3-8B (still the best price/quality embedder on OpenRouter —
see the 2026-07 model evaluation), add `dimensions: 1536` to the request body,
update `dimensions/1` and `vector_dimensions`, migrate the column to
`vector(1536)`, re-embed all chunks (~$0.25 per 50k chunks at $0.010/M), add
an HNSW index, and spot-check recall against exact results. Query and document
embeddings must use the same dims, so re-embed everything in one pass.

## Notes

- The deployed homelab server predates the `stats` MCP tool (commit e533134);
  redeploy to get it.
- Benchmarking gotcha: the MCP server responds 202 to POSTed tool calls and
  delivers results as SSE events on the held-open `initialize` connection.
  Naive curl timing measures only the 202, not the result; correlate SSE
  events by JSON-RPC id.

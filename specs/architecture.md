# Architecture

## System Diagram

```
Claude Code / MCP Client              curl / scripts / CLI
        │                                     │
        │ MCP (Streamable HTTP + SSE)         │ HTTP REST API
        │                                     │
┌───────▼─────────────────────────────────────▼──┐
│  KB host (private network)                     │
│                                                │
│  ┌──────────────────┐  ┌────────────────────┐  │
│  │  Anubis MCP      │  │  Plug Router       │  │
│  │  (search, mgmt,  │  │  (file upload,     │  │
│  │   URL ingest)    │  │   text ingest,     │  │
│  │                  │  │   health check)    │  │
│  └────────┬─────────┘  └──────────┬─────────┘  │
│           │       Bandit          │             │
│           └───────────┬───────────┘             │
│                       │                         │
│  ┌────────────────────▼──────────────────────┐  │
│  │  Arcana (RAG Engine)                      │  │
│  │  ┌──────────┐  ┌────────────────┐         │  │
│  │  │ Chunker  │  │ Embedder       │         │  │
│  │  │ (450tok  │  │ (qwen3-8b via  │         │  │
│  │  │  +50     │  │  OpenRouter)   │         │  │
│  │  │  overlap)│  │  4096-dim      │         │  │
│  │  └──────────┘  └────────────────┘         │  │
│  │  ┌──────────┐  ┌────────────────┐         │  │
│  │  │ Search   │  │ VectorStore    │         │  │
│  │  │ (hybrid) │  │ (pgvector)     │         │  │
│  │  └──────────┘  └────────────────┘         │  │
│  └────────────────────┬──────────────────────┘  │
│                       │                         │
│  ┌────────────────────▼──────────────────────┐  │
│  │  Oban (Background Jobs)                   │  │
│  │  - Ingestion pipeline                     │  │
│  │  - URL scraping                           │  │
│  │  - Chunking + embedding                   │  │
│  └────────────────────┬──────────────────────┘  │
│                       │                         │
└───────────────────────┼─────────────────────────┘
                        │
              ┌─────────▼─────────┐
              │  PostgreSQL 18     │
              │  + pgvector        │
              │  (host server)     │
              └───────────────────┘
                        │
              ┌─────────▼─────────┐
              │  OpenRouter API    │
              │  (embeddings only) │
              └───────────────────┘
```

## Key Design Decisions

### No Phoenix

The app uses Bandit directly (via Anubis MCP's Plug integration). There is no web UI, no HTML rendering, no LiveView. Phoenix would be unnecessary overhead.

### Arcana as Library

Arcana provides the entire RAG pipeline — chunking, embedding, vector storage, search. We use it as a library dependency, implementing a custom `Embedder` module for OpenRouter/qwen3-embedding-8b.

### MCP + HTTP API Split

MCP is the primary interface for agents (search, source management, URL ingestion). But ingesting large content (books, PDFs, long transcripts) via MCP would bloat the agent's context window — the full text would appear in the tool call arguments. A separate HTTP API handles large-payload ingestion:

- **MCP** (via Anubis): search, list/get/delete/update sources, ingest_url, find_related — all small payloads
- **HTTP API** (via Plug): file upload (PDF, epub), large text/transcript ingestion — multipart/form-data, no context window impact

Both interfaces share the same Bandit server and call into the same Arcana pipeline.

### Anubis MCP as Interface Layer

Anubis MCP handles MCP protocol concerns (transport, session management, tool registration). MCP tool handlers call into Arcana's API.

### Router Composition

Both the Anubis MCP handler and the Plug HTTP API run under a single Bandit listener on port 4000. A top-level `KB.Router` Plug pattern-matches on path prefix to dispatch:

- `/mcp/*` → forwarded to the Anubis MCP handler
- `/api/*` → forwarded to `KB.API.Router` (Plug's `forward` macro strips the matched prefix, so `KB.API.Router` receives `/ingest/file` rather than `/api/ingest/file`)
- `/health` → handled directly by `KB.Router` (returns `200 OK`, not forwarded to `KB.API.Router`)

This means a single port serves both the MCP protocol (for AI agents) and the REST API (for direct clients). The supervision tree (see below) already reflects this structure.

### Oban for Background Work

Ingestion is inherently async — scraping a URL, parsing a PDF, chunking, and embedding takes time. Oban provides:
- Job queues with retries and backoff
- Per-worker uniqueness so a re-ingest of the same content joins the running job
- Observability (job status, error tracking)

### Tags, Not Collections

Sources are organized with freeform tags rather than hierarchical collections. This keeps the data model simple and allows cross-cutting categorization. Arcana supports collections natively but we'll use tags on the source metadata instead.

### No Auth

The service runs on a private network (Tailscale / LAN). No authentication layer needed.

## Application Supervision Tree

```
KB.Application
├── KB.Repo (Ecto)
├── Oban (Pro)
├── Bandit (port 4000)
│   ├── Anubis MCP routes (/mcp/*)
│   └── Plug routes (/api/*, /health)
└── KB.TaskSupervisor (for any async work outside Oban)
```

## Request Flow: Search

```
MCP Client → search(query: "periodization", tags: ["training"])
  → Anubis routes to KB.MCP.SearchTool
    → Arcana.search(query, mode: :hybrid, ...)
      → Embed query via KB.Embedder.OpenRouter
      → pgvector cosine similarity + tsvector fulltext
      → Weighted score fusion
    → Return ranked chunks with scores and source metadata
  → MCP response to client
```

## Request Flow: Ingest URL

```
MCP Client → ingest_url(url: "https://...", tags: ["product-dev"])
  → Anubis routes to KB.MCP.IngestUrlTool
    → Check for duplicate URL unless force=true (see [Cross-Cutting Rules — Deduplication](overview.md#deduplication))
    → Create source record (status: :pending)
    → Enqueue KB.Workers.IngestUrl Oban job
    → Return source_id + status immediately
  → Oban picks up job:
    → Update source status: :processing
    → Scrape URL with Req
    → Extract text content, compute content_hash
    → Arcana.ingest(text, metadata: %{url: url, tags: tags})
      → Chunk (450 tokens, 50 overlap)
      → Embed each chunk in batches of 20 via OpenRouter
      → Store in pgvector
    → Update source: status: :completed, chunk_count: N, arcana_document_id: doc_id
    → On failure: status: :failed, error: message
```

## Request Flow: Ingest File (HTTP API)

```
curl / script → POST /api/ingest/file (multipart: file + tags)
  → KB.API.Router handles upload
    → Read file binary, detect type from extension, compute content_hash
    → Check for duplicate content unless force=true (see [Cross-Cutting Rules — Deduplication](overview.md#deduplication))
    → Create source record (status: :pending)
    → Enqueue KB.Workers.IngestContent Oban job
      > **Note**: File content is written to a temp file and the file path is passed in Oban job
      > args (not the content itself). This avoids bloating the `oban_jobs` table with large text
      > payloads. The worker reads from the temp file, then deletes it after ingestion.
    → Return 202 Accepted with source_id
  → Oban picks up job:
    → Update source status: :processing
    → Parse file (PDF → text, epub → text)
    → Compute content_hash (SHA-256)
    → Arcana.ingest(text, metadata: %{filename: ..., tags: tags})
      → Chunk → Embed (batches of 20) → Store
    → Update source: status: :completed, chunk_count: N, arcana_document_id: doc_id
    → On failure: status: :failed, error: message
```

## Testing Strategy

### Approach

Lightweight test suite appropriate for a personal project. Focus on the parts most likely to break.

### Unit Tests

- **Parsers** (`KB.Parsers.Html`, `KB.Parsers.Epub`): Test content extraction with fixture files. These are pure functions — easy to test, high value.
- **Sources context** (`KB.Sources`): Test dedup logic, tag queries, CRUD operations against a test database.
- **Embedder** (`KB.Embedder.OpenRouter`): Test request formation and response parsing. Mock the HTTP calls to OpenRouter (don't burn API credits in tests).

### Integration Tests

- **Ingestion pipeline**: Test the full flow from raw content → source record → chunks in DB. Use the test database with pgvector. Mock only the OpenRouter embedding call (return a fixed 4096-dim vector).
- **MCP tools**: Test each tool handler with real DB state. Verify correct responses and error cases.
- **HTTP API**: Test file upload and text ingestion endpoints via `Plug.Test`.

### What NOT to Test

- Arcana internals (it has its own tests)
- Oban job infrastructure (tested by Oban)
- MCP protocol handling (tested by Anubis)

### Test Database

Standard Ecto sandbox (`Ecto.Adapters.SQL.Sandbox`). Requires a local PostgreSQL with pgvector for development.

### Running Tests

```bash
mix test                     # all tests
mix test --only integration  # integration tests only
```

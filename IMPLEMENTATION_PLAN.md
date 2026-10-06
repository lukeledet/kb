# Implementation Plan — KB

A phased plan to build the KB personal knowledge base from specs to working system. Each phase builds on the previous one and ends with a verifiable milestone.

---

## Phase 1: Project Scaffold & Database Foundation

**Goal**: Bootable Elixir app with Ecto, pgvector, and the `sources` table migrated.

### Task 1.1 — Initialize Elixir Project
- `mix new kb --sup` (or `mix igniter.new kb`)
- Set up `.tool-versions` / `mise` (Elixir 1.18+, OTP 27+)
- Add core deps to `mix.exs`: `ecto_sql`, `postgrex`, `jason`, `bandit`, `plug`, `req`, `floki`
- Add Oban Pro as a local path dep: `{:oban_pro, path: "../oban_pro"}`
- Add `arcana` and `anubis` from hex (public packages)
- Configure `.formatter.exs`
- Load environment from `.env` (contains `OPENROUTER_API_KEY`)
- **Acceptance**: `mix compile` succeeds, all deps fetched

### Task 1.2 — Configure Ecto + pgvector
- Create `KB.Repo`
- Configure `config/config.exs`, `dev.exs`, `test.exs`, `runtime.exs` with `DATABASE_URL`
- Create dev/test databases with `mix ecto.create`
- Enable pgvector extension in a migration: `CREATE EXTENSION IF NOT EXISTS vector`
- **Acceptance**: `mix ecto.create && mix ecto.migrate` runs clean; `SELECT vector '[1,2,3]'` works in psql

### Task 1.3 — Arcana Installation & Schema Alignment
- Run `mix arcana.install` to generate Arcana migrations (`arcana_documents`, `arcana_chunks`)
- Create a follow-up migration to alter `arcana_chunks.embedding` from `vector(384)` to `vector(4096)`
- Recreate HNSW index with `m=16, ef_construction=128`
- Configure Arcana in `config.exs` (repo, embedder module, chunk_size: 450, chunk_overlap: 50, vector_dimensions: 4096)
- **Acceptance**: Migrations run; `\d arcana_chunks` shows `embedding vector(4096)`; HNSW index exists

### Task 1.4 — Sources Table Migration & Schema
- Create migration for `sources` table per data-model spec (binary_id PK, all columns, indexes)
- Indexes: GIN on `tags`, partial unique on `url`, partial unique on `content_hash`, partial unique on `arcana_document_id`, B-tree on `status`
- Create `KB.Sources.Source` Ecto schema
- **Acceptance**: Migration runs; `KB.Sources.Source` changeset validates required fields

### Task 1.5 — Oban Pro Configuration
- Oban Pro is a local path dep (`../oban_pro/`) — no private hex repo needed
- Configure Oban in `config.exs` with `KB.Repo`, queues: `[ingestion: 2]`
- Set `max_attempts: 5` with exponential backoff
- Run Oban migrations
- **Acceptance**: App boots with Oban running; `Oban.config()` returns expected queues

### Task 1.6 — Application Supervision Tree
- Wire `KB.Application` with children: `KB.Repo`, `Oban`, `{Bandit, plug: KB.Router, port: 4000}`, `{Task.Supervisor, name: KB.TaskSupervisor}`
- Create stub `KB.Router` (Plug.Router) that returns 200 on `/health`
- **Acceptance**: `mix run --no-halt` boots; `curl localhost:4000/health` returns `{"status":"ok","version":"0.1.0"}`

---

## Phase 2: Embedder & Sources Context

**Goal**: OpenRouter embedder working, Sources CRUD with dedup logic implemented.

### Task 2.1 — KB.Embedder.OpenRouter
- Implement `Arcana.Embedder` behaviour (`embed/2`, `embed_batch/2`, `dimensions/1`)
- Call OpenRouter embedding API via `Req` for `qwen/qwen3-embedding-8b`
- Batch size: 20 texts per API call
- Read `OPENROUTER_API_KEY` from env
- **Acceptance**: `KB.Embedder.OpenRouter.embed("hello world")` returns `{:ok, vector}` with 4096 dims; `embed_batch/2` works with list of texts

### Task 2.2 — KB.Sources Context Module
- Implement `KB.Sources` with functions:
  - `create_source/1` — insert with status `:pending`
  - `get_source/1`, `get_source!/1`
  - `list_sources/1` — with optional `tags`, `status`, `limit`, `offset` filters
  - `update_source/2`
  - `delete_source/1` — deletes Arcana document first (cascade to chunks), then source
  - `update_tags/2` — replace tags array
  - `list_tags/0` — aggregate distinct tags with counts
  - `find_by_url/1` — for URL dedup
  - `find_by_content_hash/1` — for content dedup
- Dedup logic: check URL or content_hash, return existing unless `force: true`
- **Acceptance**: Unit tests pass for all CRUD operations and dedup scenarios against test DB

---

## Phase 3: Ingestion Pipeline

**Goal**: Content flows from raw input through Oban workers to embedded, searchable chunks in pgvector.

### Task 3.1 — HTML Parser (KB.Parsers.Html)
- Extract main content from HTML using priority: `<article>` → `<main>` → `[role="main"]` → largest `<div>` → `<body>`
- Strip `<script>`, `<style>`, `<nav>`, `<footer>`, `<header>`, `<aside>`, `<form>`
- Extract page title from `<title>` tag
- Uses `Floki` for parsing
- **Acceptance**: Unit tests with HTML fixture files return clean text content

### Task 3.2 — Epub Parser (KB.Parsers.Epub)
- Unzip epub, parse `META-INF/container.xml` → find OPF
- Parse OPF for spine reading order
- Extract text from each XHTML file in spine order via `Floki`
- Extract metadata (title, author) from OPF manifest
- **Acceptance**: Unit test with a real `.epub` fixture returns ordered chapter text + metadata

### Task 3.3 — IngestUrl Oban Worker
- `KB.Workers.IngestUrl` — Oban worker on `:ingestion` queue
- Pipeline: set status `:processing` → scrape URL with `Req` → parse HTML → compute SHA-256 `content_hash` → call `Arcana.ingest/2` → update source (`:completed`, `chunk_count`, `arcana_document_id`)
- On failure: set status `:failed` with error message
- **Acceptance**: Integration test: create source + enqueue job → source ends up `:completed` with chunks in DB (mock OpenRouter embedder to return fixed vector)

### Task 3.4 — IngestContent Oban Worker
- `KB.Workers.IngestContent` — Oban worker on `:ingestion` queue
- Reads content from temp file path in job args (path: `<tmp_dir>/kb_ingest_<source_id>.bin`)
- Parses if needed (PDF/epub → text via parsers)
- Calls `Arcana.ingest/2` → updates source
- Deletes temp file after successful ingestion; leaves in place on failure for retry
- **Acceptance**: Integration test: write temp file → enqueue job → source `:completed` → temp file deleted

### Task 3.5 — Startup Temp File Cleanup
- On application boot, sweep `System.tmp_dir!/0` for orphaned `kb_ingest_*` files
- Delete files older than 24 hours
- **Acceptance**: Orphaned temp files are cleaned up on restart

---

## Phase 4: Search & Retrieval

**Goal**: Hybrid search with tag filtering and find-related working end-to-end.

### Task 4.1 — KB.Search Module — Tag-Filtered Hybrid Search
- Custom SQL query joining `sources.tags` → `arcana_documents` → `arcana_chunks`
- Support `:hybrid`, `:semantic`, `:fulltext` modes
- pgvector cosine similarity + tsvector fulltext with weighted score fusion
- Parameters: `query`, `tags`, `limit`, `threshold`, `mode`
- Tag filtering uses `&& ARRAY[...]` (overlap operator)
- **Acceptance**: Integration test: ingest 2 sources with different tags → search with tag filter returns only matching source's chunks; hybrid mode returns fused scores

### Task 4.2 — KB.Search — Find Related
- Compute source centroid by averaging chunk embeddings
- Search for chunks near centroid, excluding the source's own `arcana_document_id`
- Group results by source, rank by average similarity
- Return top N related sources with `top_chunk_text`
- **Acceptance**: Integration test: ingest 3 sources → `find_related` for source A returns B and C ranked by similarity

### Task 4.3 — Set HNSW ef_search Parameter
- Set `ef_search = 100` as a query-time parameter (via `SET LOCAL hnsw.ef_search = 100` or Ecto connection init)
- **Acceptance**: Verify parameter is set during search queries

---

## Phase 5: MCP Tools

**Goal**: All 9 MCP tools registered and functional via Anubis.

### Task 5.1 — Anubis MCP Server Setup
- Configure `KB.MCP.Server` with Anubis (server name: `kb`, version: `0.1.0`)
- Register all tool modules
- Wire MCP routes under `/mcp/*` in `KB.Router`
- **Acceptance**: MCP client can connect to `localhost:4000/mcp` and list available tools

### Task 5.2 — Search Tool (`KB.MCP.Tools.SearchTool`)
- Input: `query`, `tags`, `limit`, `mode`, `threshold`
- Calls `KB.Search` module
- Returns results in spec'd JSON format (chunks with scores + source metadata)
- **Acceptance**: MCP call with query returns ranked chunks

### Task 5.3 — Ingest URL Tool (`KB.MCP.Tools.IngestUrlTool`)
- Input: `url`, `title`, `tags`, `force`
- Dedup check → create source → enqueue `IngestUrl` worker
- Returns source_id + status
- **Acceptance**: MCP call ingests URL; duplicate URL returns existing source

### Task 5.4 — Source Management Tools
- `ListSourcesTool` — with `tags`, `status`, `limit`, `offset` filters; returns `total` + `has_more`
- `GetSourceTool` — full source details by ID
- `DeleteSourceTool` — deletes source + Arcana document + chunks
- `UpdateTagsTool` — replaces tags array
- `ListTagsTool` — aggregated tag list with counts
- `GetChunksTool` — paginated chunks by source_id (text only, no embeddings)
- **Acceptance**: Each tool handles happy path and "source not found" error per spec

### Task 5.5 — Find Related Tool (`KB.MCP.Tools.FindRelatedTool`)
- Input: `id`, `limit`
- Calls `KB.Search.find_related/2`
- Returns related sources with similarity scores and top chunk text
- Error: "Source has no chunks" if source is pending/failed
- **Acceptance**: MCP call returns related sources; error cases handled

---

## Phase 6: HTTP API

**Goal**: File upload and text ingestion endpoints working alongside MCP.

### Task 6.1 — Router Composition
- `KB.Router` dispatches: `/mcp/*` → Anubis, `/api/*` → `KB.API.Router`, `/health` → inline handler
- Configure `Plug.Parsers` in `KB.API.Router` with 100 MB limit
- **Acceptance**: All three path prefixes route correctly

### Task 6.2 — POST /api/ingest/file
- Accept multipart upload (`file`, `title`, `tags`, `metadata`, `force`)
- Detect type from file extension (`.pdf`, `.epub` only; reject others with 400)
- Compute SHA-256 content hash → dedup check
- Write content to temp file → create source → enqueue `IngestContent` worker
- Return 202 with source JSON; return 200 with existing source on dedup hit
- **Acceptance**: `Plug.Test` integration: upload PDF → 202 response with source_id; duplicate upload → 200 with existing source

### Task 6.3 — POST /api/ingest/text
- Accept JSON body (`text`, `title`, `source_type`, `tags`, `metadata`, `force`)
- Validate: `text` required, `source_type` must be `text` or `transcript`
- Compute SHA-256 → dedup check
- Write to temp file → create source → enqueue `IngestContent` worker
- Return 202 / 200 (dedup)
- **Acceptance**: `Plug.Test` integration: post text → 202; post same text → 200

### Task 6.4 — GET /api/sources/:id
- Return source status JSON (for polling after async ingestion)
- 404 if not found
- **Acceptance**: Returns correct status through pending → completed lifecycle

---

## Phase 7: Testing & Hardening

**Goal**: Confidence that the system works correctly before deployment.

### Task 7.1 — Unit Tests
- `KB.Parsers.Html` — fixture-based content extraction tests
- `KB.Parsers.Epub` — fixture-based epub parsing tests
- `KB.Sources` — CRUD, dedup, tag queries against test DB
- `KB.Embedder.OpenRouter` — request formation/response parsing (mocked HTTP)

### Task 7.2 — Integration Tests
- Full ingestion pipeline: content → source → chunks in DB (mock embedder)
- MCP tool handlers with real DB state
- HTTP API endpoints via `Plug.Test`
- Search with tag filtering, multiple modes

### Task 7.3 — Error Path Validation
- Invalid URL format rejection
- Unsupported file type rejection
- Source not found errors across all tools
- Oban job failure → source status `:failed` with error message
- 413 for oversized uploads

---

## Phase 8: Deployment

**Goal**: KB running on the host server, accessible on the private network on port 4000.

### Task 8.1 — Dockerfile
- Multi-stage build: compile release → minimal runtime image
- Install poppler-utils and unzip in runtime stage
- Handle Oban Pro as a local path dep (copy `../oban_pro/` into build context)
- **Acceptance**: `docker build` succeeds; container starts and passes health check

### Task 8.2 — docker-compose.yml & Environment
- Service config with port mapping, env vars, restart policy
- Create `.env.example` with all required variables
- **Acceptance**: `docker-compose up` boots app; health check passes

### Task 8.3 — Infrastructure Setup (via `../infra` repo)
- Use the existing infra tooling/repo to configure the host server:
  - Create `kb_prod` database on existing PostgreSQL 18 instance
  - Enable pgvector extension
  - Configure a private DNS name → host server IP
  - Set up `pg_dump` backup cron (daily at 3 AM, 30-day retention)
- Run migrations from container
- Verify MCP connectivity from Claude Code
- **Acceptance**: `curl <kb-host>:4000/health` returns OK; backup cron active

---

## Phase Summary

| Phase | Description | Key Deliverable |
|-------|-------------|-----------------|
| 1 | Project Scaffold & Database | Bootable app with all tables migrated |
| 2 | Embedder & Sources Context | OpenRouter embedder + Sources CRUD with dedup |
| 3 | Ingestion Pipeline | URL + content ingestion via Oban workers |
| 4 | Search & Retrieval | Hybrid search with tag filtering + find-related |
| 5 | MCP Tools | All 9 tools registered and functional |
| 6 | HTTP API | File upload + text ingestion endpoints |
| 7 | Testing & Hardening | Unit + integration tests, error paths |
| 8 | Deployment | Docker on the host server, DNS, backups |

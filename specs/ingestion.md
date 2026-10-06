# Ingestion Pipeline

## Overview

Ingestion is the process of taking raw content (URL, PDF, epub, text, transcript) and converting it into embedded, searchable chunks. All ingestion runs asynchronously via Oban workers.

## Supported Source Types

> See [Data Model — Source Types](data-model.md#source-types) for the canonical `source_type` enum definition.

### 1. URL

**Flow**: URL → Scrape → Extract text → Chunk → Embed → Store

- Scrape with `Req` (follows redirects, handles common HTTP issues)
- Parse HTML with `Floki`, extract main content (strip nav, footer, ads)
- Store original URL in source metadata
- Handle multi-page content? **v1: single page only**

**Challenges**:
- JavaScript-rendered pages won't scrape well (acceptable limitation for v1)
- Need to extract "main content" heuristically (look for `<article>`, `<main>`, or largest text block)

### 2. PDF

**Flow**: PDF binary → Extract text → Chunk → Embed → Store

- Accept PDF uploads via HTTP API (`POST /api/ingest/file`)
- Text extraction via Arcana's parser or `pdf_text` / poppler
- Preserve document structure where possible (chapters, sections)
- Store filename and page count in metadata

### 3. Epub

**Flow**: Epub binary → Extract text → Chunk → Embed → Store

- Epub is a zip of XHTML files — parse with `:zip` + `Floki`
- Extract text from each chapter/section in order
- Store book metadata (title, author) from epub's OPF manifest
- May need a hex package for epub parsing (or roll a simple one)

### 4. Plain Text / Markdown

**Flow**: Text → Chunk → Embed → Store

- Simplest path — text goes directly to chunker
- Markdown: strip formatting or preserve it? **Preserve it** — chunk boundaries should respect heading structure where possible
- Accept via HTTP API (`POST /api/ingest/text`) with title and tags

### 5. Transcript (YouTube / Podcast)

**Flow**: Transcript text → Chunk → Embed → Store

- Ingested as plain text via HTTP API (`POST /api/ingest/text`)
- Source type set to `transcript` for metadata purposes
- User obtains transcript externally (yt-dlp, podcast app, etc.)
- Store source URL (YouTube link, podcast episode URL) in metadata if provided

## Oban Job Design

### Workers

```
KB.Workers.IngestUrl     — scrape URL + ingest text
KB.Workers.IngestContent — chunk + embed + store (shared by all types)
```

### IngestUrl Pipeline

```
1. MCP tool handler receives URL
2. Check for duplicate (existing source with same URL) — return existing if found, unless `force: true`
3. Create source record (status: :pending) and return source_id to client immediately
4. Enqueue KB.Workers.IngestUrl Oban job with source_id
5. Oban picks up job:
   a. Update source status: :processing
   b. Scrape URL with Req
   c. Parse HTML, extract text with Floki
   d. Compute content_hash (SHA-256) and store on source
   e. Call Arcana.ingest(text, ...) which chunks → embeds → stores
   f. Update source record (status: :completed, chunk_count: N, arcana_document_id: doc_id)
6. On failure: Update source status: :failed with error message
```

### IngestContent Pipeline (for non-URL sources)

```
1. HTTP handler receives content (file binary or text body)
2. Compute content_hash (SHA-256) — check for duplicate, return existing if found unless `force: true` (see [Cross-Cutting Rules — Deduplication](overview.md#deduplication))
3. Create source record (status: :pending) and return source_id via 202 response
4. Enqueue KB.Workers.IngestContent Oban job with source_id + content reference

  > **Note (Content Passing)**: For text/file ingestion, content is written to a temporary file
  > on disk (using `System.tmp_dir!/0` + a unique filename) and the **file path** is passed in
  > the Oban job args — NOT the raw content. This avoids bloating the `oban_jobs` table
  > (which stores args as JSONB in Postgres) with large text payloads. The Oban worker reads
  > the temp file, calls `Arcana.ingest/2`, then deletes the temp file after ingestion.
  > For URL ingestion, only the URL string and source_id are passed in args (no temp file needed).

  > **Note (Temp-File Durability)**: Temp files are named using the source ID (e.g.,
  > `<tmp_dir>/kb_ingest_<source_id>.bin`) so they are deterministic and findable across
  > Oban retries. If the worker crashes before deleting the file, the next retry reuses the
  > same path. Cleanup timing: the temp file is deleted AFTER successful `Arcana.ingest/2`
  > completion; on failure it is LEFT in place for the next retry. Node restart: if the temp
  > file is missing on retry and no Arcana document was created yet, the job fails permanently
  > (content must be re-submitted by the user — acceptable since restarts are rare). A startup
  > sweep can clean up orphaned temp files on application boot.

5. Oban picks up job:
   a. Update source status: :processing
   b. Parse file if needed (PDF → text, epub → text)
   c. Call Arcana.ingest(text, ...) — chunk → embed → store
   d. Update source record (status: :completed, chunk_count: N, arcana_document_id: doc_id)
6. On failure: Update source status: :failed with error message
```

### Error Handling

- Oban retries failed jobs with exponential backoff (`max_attempts: 5` — see [Oban Setup](tech-stack.md#oban-setup))
- Source status set to `:failed` with error message on final failure — see [Cross-Cutting Rules — Status Transitions](overview.md#status-transitions)
- Common failure modes:
  - OpenRouter API timeout/rate limit → retry
  - URL unreachable → fail with message
  - PDF parse error → fail with message

### Rate Limiting

OpenRouter has rate limits. Embedding concurrency is bounded by the `:embed_max_concurrency` app config in `config/config.exs` (parallel embedding requests, each covering a batch of chunks) and by the per-queue worker concurrency. Lower `:embed_max_concurrency` if OpenRouter rate-limits (429s).

### Embedding Batch Sizing

A typical book produces 150-250 chunks, each requiring an embedding API call. To avoid hammering OpenRouter:

- `embed_batch/2` sends chunks in batches of **20** per API request
- A 200-chunk book = 10 batch API calls (vs 200 individual calls)
- Batch size is configurable via `KB.Embedder.OpenRouter` module attribute
- If OpenRouter's batch limit differs, adjust accordingly after testing

Combined with Oban's rate limiting (max 2 concurrent ingestion jobs), this keeps API usage well within limits.

### Ingestion Status Feedback

Ingestion is asynchronous — both MCP `ingest_url` and HTTP endpoints return immediately with a source_id and `status: "pending"`. The expected workflow for clients:

1. Call ingest → receive source_id
2. Poll `get_source` (MCP) or `GET /api/sources/:id` (HTTP) to check status
3. Status transitions: `pending` → `processing` → `completed` | `failed`

There is no push notification when ingestion completes. Polling is the intended mechanism. For MCP agents, the typical pattern is: ingest, continue other work, check status later.

## Content Extraction Details

### HTML → Text (URL scraping)

Priority order for finding main content:
1. `<article>` element
2. `<main>` element
3. `[role="main"]` element
4. Largest `<div>` by text content length
5. Full `<body>` as fallback

Strip: `<script>`, `<style>`, `<nav>`, `<footer>`, `<header>`, `<aside>`, `<form>`

### PDF → Text

Use Arcana's built-in PDF parser (poppler-based) or `pdf_text` package. Accept that formatting may be imperfect — this is a known limitation of PDF text extraction.

### Epub → Text

1. Unzip epub file
2. Parse `META-INF/container.xml` to find OPF file
3. Parse OPF for reading order (spine)
4. Extract text from each XHTML file in spine order
5. Concatenate with section breaks

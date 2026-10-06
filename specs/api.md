# HTTP API

## Overview

The HTTP API handles large-payload ingestion that would bloat an agent's context window if done via MCP. It runs on the same Bandit server as the MCP interface, under the `/api` path prefix.

## Why Both MCP and HTTP?

MCP tool calls pass arguments through the agent's context window. For search queries and source management, payloads are small (a query string, a source ID). But ingesting a 55K-word book or a 5MB PDF as a tool argument wastes context and may hit size limits. The HTTP API accepts these large payloads directly.

| Operation | Interface | Reason |
|-----------|-----------|--------|
| Search | MCP | Small query in, ~10 chunks out |
| Source management | MCP | Tiny payloads (IDs, tags) |
| URL ingestion | MCP | Just a URL string — server fetches content |
| File upload (PDF, epub) | HTTP API | Binary files, potentially megabytes |
| Large text / transcript | HTTP API | Full book text, transcripts |

## Limits

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max file upload | 100 MB | Covers large PDFs/epubs; Plug.Parsers `:length` set to `104_857_600` |
| Max text body | 100 MB | Same limit for JSON text ingestion |
| Request timeout | 30 seconds | Upload time for large files over LAN |

## Endpoints

Keyed documents and collections have their own endpoints under `/api/collections`. See [Keyed Documents — HTTP API](documents.md#http-api). `POST /api/ingest/text` also accepts `collection` and `key` to upsert one keyed document. `POST /api/search` takes the parameters described in [Search & Retrieval](search.md): modes, `group_by`, paging, filters, and reranking. It returns 400 for a bad parameter.

### `POST /api/ingest/file`

Upload a PDF or epub file for ingestion.

**Content-Type**: `multipart/form-data`

**Parameters**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `file` | file | Yes | The PDF or epub file |
| `title` | string | No | Title (auto-detected from file if omitted) |
| `tags` | string | No | Comma-separated tags (e.g., `"training,strength"`) |
| `metadata` | string (JSON) | No | Additional metadata as JSON |
| `force` | boolean | No | Re-ingest even if content hash matches existing source (default: false) |

**Response** (`202 Accepted`):
```json
{
  "id": "uuid",
  "title": "Rowing Stronger",
  "source_type": "pdf",
  "status": "pending",
  "tags": ["training", "strength"]
}
```

> **Deduplication**: If an existing source has the same content hash and `force` is `false`, the API returns the existing source and skips enqueueing a new job.

**Example**:
```bash
curl -X POST localhost:4000/api/ingest/file \
  -F "file=@book.pdf" \
  -F "title=Shape Up" \
  -F "tags=product-dev,basecamp"
```

---

### `POST /api/ingest/text`

Ingest a large text document or transcript. Markdown content uses `source_type: "text"` with `metadata.format: "markdown"`.

**Content-Type**: `application/json`

**Body**:
```json
{
  "text": "full text content here...",
  "title": "Shape Up - Chapter 1",
  "source_type": "text | transcript",
  "tags": ["product-dev"],
  "metadata": {
    "author": "Ryan Singer",
    "source_url": "https://youtube.com/..."
  },
  "force": false
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | Yes | The full text content |
| `title` | string | No | Title for the source |
| `source_type` | string | No | `text` or `transcript` (default: `text`) |
| `tags` | array | No | Tags to categorize this source |
| `metadata` | object | No | Additional metadata (author, source_url, etc.) |
| `force` | boolean | No | Re-ingest even if content hash matches (default: false) |

> **Note**: Markdown content uses `source_type: "text"` with `metadata.format: "markdown"`. See [Data Model — Source Types](data-model.md#source-types) for the canonical enum.

**Response** (`202 Accepted`):
```json
{
  "id": "uuid",
  "title": "Shape Up - Chapter 1",
  "source_type": "transcript",
  "status": "pending",
  "tags": ["product-dev"]
}
```

> **Deduplication**: If an existing source has the same content hash and `force` is `false`, the API returns the existing source and skips enqueueing a new job.

**Example**:
```bash
curl -X POST localhost:4000/api/ingest/text \
  -H "Content-Type: application/json" \
  -d '{"text": "...", "title": "Podcast Episode 42", "tags": ["productivity"]}'
```

---

### `GET /health`

Health check endpoint.

**Response** (`200 OK`):
```json
{
  "status": "ok",
  "version": "0.1.0"
}
```

---

### `GET /api/sources/:id`

Check the status of an ingested source. Useful for polling after async ingestion.

**Response** (`200 OK`):
```json
{
  "id": "uuid",
  "title": "Shape Up",
  "source_type": "pdf",
  "status": "completed",
  "tags": ["product-dev"],
  "chunk_count": 163,
  "error": null
}
```

**Response** (`404 Not Found`):
```json
{
  "error": "Source not found"
}
```

---

### `GET /api/sources/:id/content`

Return the full text of a source, exactly as it was ingested. Reads the stored
document, not the chunks: chunks overlap, so joining them would repeat text at
every boundary.

**Response** (`200 OK`):
```json
{
  "id": "uuid",
  "title": "Shape Up",
  "url": null,
  "source_type": "pdf",
  "chunk_count": 163,
  "content": "full text of the source..."
}
```

**Response** (`409 Conflict`) — the source exists but has no document yet
(still pending, still processing, or it failed):
```json
{
  "error": "Source has no content (status: pending)"
}
```

**Response** (`404 Not Found`):
```json
{
  "error": "Source not found"
}
```

## Error Responses

All errors return JSON:

```json
{
  "error": "description of what went wrong"
}
```

| Status | Meaning | Example Response |
|--------|----------|--------------|
| 400 | Missing required `text` field | `{"error": "text field is required"}` |
| 400 | Missing required `file` field | `{"error": "file field is required"}` |
| 400 | Unsupported file type (not PDF/epub) | `{"error": "Unsupported file type: .doc. Accepted: .pdf, .epub"}` |
| 404 | Source not found (`GET /api/sources/:id`) | `{"error": "Source not found"}` |
| 409 | Source has no ingested content yet (`GET /api/sources/:id/content`) | `{"error": "Source has no content (status: pending)"}` |
| 413 | File exceeds 100 MB limit | `{"error": "Request body too large. Maximum: 100 MB"}` |
| 422 | PDF/epub parsing failure | `{"error": "Failed to parse file: [reason]"}` |
| 500 | Internal server error | `{"error": "Internal server error"}` |

> **Deduplication**: Duplicate content (same content hash with `force=false`) returns `200` with the existing source — not a `4xx` error. See [Cross-Cutting Rules — Deduplication](overview.md#deduplication) for full semantics.

## Plug Router

The API uses a simple `Plug.Router`. The top-level `KB.Router` forwards requests to `KB.API.Router` with the `/api` prefix already stripped, so routes here are defined without it. The `/health` endpoint is handled directly by `KB.Router` and does not appear here.

```elixir
defmodule KB.API.Router do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    json_decoder: Jason,
    length: 104_857_600  # 100 MB

  plug :match
  plug :dispatch

  post "/ingest/file" do
    # Handle multipart file upload
  end

  post "/ingest/text" do
    # Handle JSON text body
  end

  get "/sources/:id" do
    # Return source status
  end
end
```

This router is composed with the Anubis MCP router under a single Bandit server.

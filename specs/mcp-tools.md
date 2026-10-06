# MCP Tools

## Overview

The KB exposes search and management functionality through MCP tools via Anubis MCP. Large-payload ingestion (file uploads, long text) is handled by the [HTTP API](api.md) instead, to avoid bloating the agent's context window.

## Transport

- **Protocol**: MCP over Streamable HTTP + SSE
- **Host**: the machine running the KB container
- **Port**: 4000
- **Auth**: None (private network only)

## Server Identity

- **Name**: `kb`
- **Description**: Personal knowledge base — search books, articles, transcripts, and notes via semantic + full-text hybrid search
- **Version**: `0.1.0`

## Tool Definitions

The tools for keyed documents and links (`get_document_tool`, `multi_get_tool`, `upsert_document_tool`, `delete_document_tool`, `collection_status_tool`, `backlinks_tool`, `outlinks_tool`, and `link_report_tool`) are specified in [Keyed Documents — MCP tools](documents.md#mcp-tools). The server exposes every tool under its module name, so `search` below is `search_tool` on the wire.

### `search`

Search the knowledge base. The full behaviour, parameters, and response
shape are in [Search & Retrieval](search.md); this is the summary.

**Parameters**: `query` (required), `mode` (`hybrid`, `semantic`, `keyword`;
`fulltext` is the old name for `keyword`), `group_by` (`chunk` or
`document`), `limit` (max 100), `offset`, `collection`, `key_prefix`,
`collections` (list), `tags`, `source_type`, `frontmatter` (object),
`updated_after`, `rerank`, `rerank_top_n`, `rerank_model`,
`latency_budget_ms`, `full_frontmatter`, and `threshold`.

**Returns**: `results`, `total`, `query`, `mode`, `group_by`, `offset`,
`limit`, `timings` (`embed_ms`, `sql_ms`, `rerank_ms`, `total_ms`),
`embedding_used`, `reranked`, `degraded`, and `warnings`.

Chunk results keep the original fields (`chunk_id`, `text`, `score`,
`chunk_index`, and `source` with `id`, `title`, `url`, `tags`,
`source_type`) and add `scores`, `heading_path`, `snippet`, and `collection`
and `key` on `source`. Document results carry the document's fields plus its
best chunk's `heading_path`, `snippet`, `chunk_id`, and `chunk_index`.

### `ingest_url`

Ingest a web page into the knowledge base.

**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "url": {
      "type": "string",
      "description": "The URL to scrape and ingest"
    },
    "title": {
      "type": "string",
      "description": "Optional: title for the source (auto-detected from page if omitted)"
    },
    "tags": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Tags to categorize this source"
    },
    "force": {
      "type": "boolean",
      "default": false,
      "description": "Force re-ingestion even if URL was already ingested (deletes existing source first)"
    }
  },
  "required": ["url"]
}
```

**Returns**: Source ID and status. Ingestion runs asynchronously — source status transitions from `pending` → `processing` → `completed`/`failed`.

> **Status polling**: Ingestion runs asynchronously. Poll `get_source` with the returned source_id to check progress. Status transitions: `pending` → `processing` → `completed` | `failed`.

> **Deduplication**: If the URL already exists and `force` is `false`, the tool returns the existing source and does not enqueue a new ingestion job.

---

> **Note**: `ingest_text` and `ingest_file` are handled by the [HTTP API](api.md), not MCP. This avoids passing large content (book text, PDF binaries) through the agent's context window.

---

### `list_sources`

List all sources in the knowledge base.

**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "tags": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Optional: filter to sources with any of these tags"
    },
    "status": {
      "type": "string",
      "enum": ["pending", "processing", "completed", "failed"],
      "description": "Optional: filter by ingestion status"
    },
    "limit": {
      "type": "integer",
      "default": 20,
      "description": "Max sources to return (default: 20)"
    },
    "offset": {
      "type": "integer",
      "default": 0,
      "description": "Number of sources to skip for pagination"
    }
  }
}
```

**Returns**: List of sources with id, title, source_type, tags, status, chunk_count, timestamps, plus `total` count and `has_more` flag for pagination.

**Output Schema**:
```json
{
  "type": "object",
  "properties": {
    "sources": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id":          { "type": "string" },
          "title":       { "type": "string" },
          "source_type": { "type": "string" },
          "tags":        { "type": "array", "items": { "type": "string" } },
          "status":      { "type": "string", "enum": ["pending", "processing", "completed", "failed"] },
          "chunk_count": { "type": "integer" },
          "inserted_at": { "type": "string", "format": "date-time" },
          "updated_at":  { "type": "string", "format": "date-time" }
        }
      }
    },
    "total":    { "type": "integer" },
    "has_more": { "type": "boolean" }
  }
}
```

---

### `get_source`

Get details about a specific source including its metadata and chunk count.

**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "id": {
      "type": "string",
      "description": "Source ID"
    }
  },
  "required": ["id"]
}
```

**Returns**: Full source details including metadata, tags, status, chunk count, and first/last chunk preview.

**Output Schema**:
```json
{
  "type": "object",
  "properties": {
    "id":          { "type": "string" },
    "title":       { "type": "string" },
    "source_type": { "type": "string" },
    "tags":        { "type": "array", "items": { "type": "string" } },
    "status":      { "type": "string", "enum": ["pending", "processing", "completed", "failed"] },
    "chunk_count": { "type": "integer" },
    "metadata":    { "type": "object" },
    "error":       { "type": ["string", "null"] },
    "inserted_at": { "type": "string", "format": "date-time" },
    "updated_at":  { "type": "string", "format": "date-time" }
  }
}
```

---

### `delete_source`

Delete a source and all its chunks from the knowledge base.

**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "id": {
      "type": "string",
      "description": "Source ID to delete"
    }
  },
  "required": ["id"]
}
```

**Returns**: Confirmation with source title that was deleted.

---

### `update_tags`

Update the tags on a source.

**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "id": {
      "type": "string",
      "description": "Source ID"
    },
    "tags": {
      "type": "array",
      "items": { "type": "string" },
      "description": "New set of tags (replaces existing tags)"
    }
  },
  "required": ["id", "tags"]
}
```

**Returns**: Updated source with new tags.

---

### `find_related`

Find sources related to a given source based on vector similarity.

**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "id": {
      "type": "string",
      "description": "Source ID to find related sources for"
    },
    "limit": {
      "type": "integer",
      "default": 5,
      "description": "Max number of related sources to return"
    }
  },
  "required": ["id"]
}
```

**Returns**: List of related sources ranked by similarity, with the most similar chunks highlighted.

**Output Schema**:
```json
{
  "type": "array",
  "items": {
    "type": "object",
    "properties": {
      "source_id":      { "type": "string" },
      "title":          { "type": "string" },
      "source_type":    { "type": "string" },
      "tags":           { "type": "array", "items": { "type": "string" } },
      "similarity":     { "type": "number", "description": "Cosine similarity score (0.0–1.0)" },
      "top_chunk_text": { "type": "string", "description": "Text of the most similar chunk" }
    }
  }
}
```

---

### `list_tags`

List all tags in use across the knowledge base.

**Input Schema**:
```json
{
  "type": "object",
  "properties": {}
}
```

**Returns**: List of tags with source count per tag, sorted alphabetically. Example: `[{"tag": "product-dev", "count": 12}, {"tag": "training", "count": 5}]`

---

### `get_chunks`

Retrieve the text chunks of a source, for reading back ingested content.

**Input Schema**:
```json
{
  "type": "object",
  "properties": {
    "source_id": {
      "type": "string",
      "description": "Source ID to retrieve chunks for"
    },
    "offset": {
      "type": "integer",
      "default": 0,
      "description": "Chunk index to start from (for pagination)"
    },
    "limit": {
      "type": "integer",
      "default": 20,
      "description": "Max chunks to return (default: 20)"
    }
  },
  "required": ["source_id"]
}
```

**Returns**: List of chunks in order (by chunk_index) with text content, plus `total` chunk count and `has_more` flag. Chunks are returned without embeddings (text only) to keep response size manageable.

**Output Schema**:
```json
{
  "type": "object",
  "properties": {
    "chunks": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "chunk_index": { "type": "integer" },
          "text":        { "type": "string" }
        }
      }
    },
    "total":    { "type": "integer" },
    "has_more": { "type": "boolean" }
  }
}
```

---

## Error Handling

### Error Response Format

All tool errors use the standard MCP error response format:

```json
{
  "isError": true,
  "content": [{"type": "text", "text": "Error description here"}]
}
```

### Common Error Scenarios

| Tool | Error Scenario | Error Message |
|------|---------------|---------------|
| `search` | Empty query string | "Query must not be empty" |
| `ingest_url` | Invalid URL format | "Invalid URL: must start with http:// or https://" |
| `ingest_url` | URL already ingested (force=false) | Returns existing source (not an error — see Deduplication) |
| `get_source` | Source not found | "Source not found: {id}" |
| `delete_source` | Source not found | "Source not found: {id}" |
| `update_tags` | Source not found | "Source not found: {id}" |
| `find_related` | Source not found | "Source not found: {id}" |
| `find_related` | Source has no chunks (pending/failed ingestion) | "Source has no chunks — ingestion may still be in progress" |
| `get_chunks` | Source not found | "Source not found: {source_id}" |

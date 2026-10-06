# Data Model

## Overview

The data model builds on Arcana's schema (documents + chunks) with a lightweight `sources` layer on top for tracking provenance and tags.

## Schema Diagram

```
┌─────────────────────────┐
│  sources                │
├─────────────────────────┤
│  id         :binary_id  │
│  title      :string     │
│  url        :string     │  (nullable — not all sources are URLs)
│  source_type :string    │  (url, pdf, epub, text, transcript)
│  tags       {:array, :string} │
│  status     :string     │  (pending, processing, completed, failed)
│  error      :string     │  (nullable — error message if failed)
│  metadata   :map        │  (flexible: author, date, word_count, etc.)
│  arcana_document_id :binary_id │  (FK → arcana_documents.id)
│  content_hash :string   │  (nullable — SHA-256 of raw content for dedup)
│  chunk_count :integer   │
│  collection :string     │  (default "library"; see documents.md)
│  key        :text       │  (nullable — set for keyed documents)
│  slug       :text       │  (key's file name, for wikilinks)
│  frontmatter :map       │  (parsed YAML frontmatter)
│  inserted_at :utc_datetime │
│  updated_at  :utc_datetime │
└──────────┬──────────────┘
           │ 1:1
┌──────────▼──────────────┐
│  arcana_documents (Arcana) │
├─────────────────────────┤
│  id           :binary_id   │
│  content      :text        │
│  content_type :string      │
│  source_id    :string      │
│  file_path    :string      │
│  metadata     :map         │
│  status       :string      │
│  error        :string      │
│  chunk_count  :integer     │
│  collection_id :binary_id  │
│  inserted_at  :utc_datetime │
│  updated_at   :utc_datetime │
└──────────┬──────────────┘
           │ 1:N
┌──────────▼──────────────┐
│  arcana_chunks (Arcana) │
├─────────────────────────┤
│  id         :binary_id  │
│  document_id :binary_id │  (FK → arcana_documents.id)
│  text       :text       │
│  embedding  :vector(4096) │
│  chunk_index :integer   │
│  token_count :integer   │
│  metadata   :map        │
│  inserted_at :utc_datetime │
│  updated_at  :utc_datetime │
└─────────────────────────┘
```

## Notes

### Sources vs Arcana's Documents

**Decision: Wrap Arcana with our own `sources` table.**

Arcana creates its own `arcana_documents` table internally. We maintain a parallel `sources` table that adds KB-specific concerns (tags, source_type, status tracking, provenance). The link between them:

- `sources.arcana_document_id` references the Arcana document ID
- A pending source is created before ingestion starts; once `Arcana.ingest/2` returns the Arcana document ID, the worker stores it on the source record
- When deleting a source, we delete the Arcana document first (which cascades to its chunks), then delete our source record

This keeps Arcana as a clean library dependency — we don't modify its schema or fight its conventions. Our `sources` table is the user-facing layer; Arcana's `arcana_documents` and `arcana_chunks` tables are the RAG engine internals. Search joins source metadata through `sources.arcana_document_id → arcana_documents.id → arcana_chunks.document_id`, rather than a hypothetical direct foreign key from chunks to sources.

### Deduplication

Content-hash dedup applies only to library sources, which have no key. A keyed document is identified by its collection and key instead. See [Keyed Documents](documents.md).

See [Cross-Cutting Rules — Deduplication](overview.md#deduplication) for the canonical deduplication rules.

Sources are checked for duplicates before ingestion:

- **URL sources**: Check `sources.url` for exact match. If found, return the existing source (don't re-ingest). The agent sees a response indicating the URL was already ingested, with the existing source ID.
- **File/text sources**: Compute SHA-256 of raw content. Store as `sources.content_hash`. Check for existing match before ingesting. If found, return existing source.
- **Override**: Both `ingest_url` (MCP) and HTTP endpoints accept a `force: true` parameter to re-ingest, which deletes the existing source and creates a new one.

This prevents accidental duplicates (the common case) while allowing intentional re-ingestion when content has changed.

### Source Types

The canonical `source_type` enum values are:

| Value | Description |
|-------|-------------|
| `url` | Web page scraped from a URL |
| `pdf` | PDF document uploaded by user |
| `epub` | EPUB ebook uploaded by user |
| `text` | Plain text content |
| `transcript` | Audio/video transcript |
| `markdown` | A keyed markdown document, with frontmatter and heading-aware chunks. See [Keyed Documents](documents.md). |

> **Note**: Markdown sent through `POST /api/ingest/text` without a key is still `source_type: "text"`. All other spec files cross-reference this section as the canonical definition.

### Content Lifecycle

Raw text content is stored in `arcana_documents.content` by Arcana during ingestion. This has the following implications:

- **Re-embedding (model migration)**: No need to re-scrape URLs or re-upload files. The Oban worker reads `arcana_documents.content` directly to generate new embeddings with a different model.
- **File uploads (PDF/epub)**: Arcana stores the parsed text in `arcana_documents.content`. The original binary file is not retained after ingestion completes.
- **URL sources**: The scraped and extracted text is stored in `arcana_documents.content`.
- **Content recovery**: Content is always recoverable from the Arcana document for re-embedding purposes, as long as the `arcana_documents` row exists.

### Tags

Tags are stored as a Postgres array (`text[]`). This supports:
- Filtering: `WHERE 'product-dev' = ANY(tags)`
- Multiple tags per source: `["product-dev", "shape-up", "basecamp"]`
- GIN index for fast array containment queries

### Embedding Dimensions

4096 dimensions (qwen3-embedding-8b). Storage per vector: 4096 * 4 bytes = 16KB. At 200 chunks per book, a single book uses ~3.2MB of vector storage. Thousands of sources would remain well under 1GB.

### Indexes

| Index | Column | Type | Purpose |
|-------|--------|------|---------|
| HNSW | arcana_chunks.embedding | `vector_cosine_ops` | Similarity search |
| GIN | arcana_chunks.text (tsvector) | Full-text | Hybrid search |
| GIN | sources.tags | Array containment | Tag filtering |
| Unique | sources.arcana_document_id | B-tree (partial, WHERE arcana_document_id IS NOT NULL) | 1:1 source ↔ document mapping |
| B-tree | sources.status | Equality | Status filtering |
| Unique | sources.url | B-tree (partial, WHERE url IS NOT NULL) | URL dedup |
| Unique | sources.content_hash | B-tree (partial, WHERE content_hash IS NOT NULL) | Content dedup |

### HNSW Index Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| `m` | 16 | pgvector default — sufficient for <100K vectors |
| `ef_construction` | 128 | Double the pgvector default of 64; better graph quality during index build |
| `ef_search` | 100 | Query-time parameter; gives 97–99% recall for RAG use case |

At expected scale (<100K vectors, 4096 dimensions), these parameters balance build speed with search quality. Below ~10K vectors, pgvector performs a sequential scan anyway, so HNSW only matters as the collection grows.

### Chunking Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Chunk size | 450 tokens (~340 words) | Arcana default, good balance of context vs precision |
| Overlap | 50 tokens | Preserves context across chunk boundaries |
| Expected chunks per book | 150-250 | 55K words / 340 words ≈ 163 chunks |

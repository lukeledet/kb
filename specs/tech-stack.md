# Tech Stack

## Core Dependencies

| Package | Purpose | Notes |
|---------|---------|-------|
| `arcana` | RAG pipeline (chunking, embedding, search, pgvector) | Custom embedder for OpenRouter |
| `anubis` | MCP server (Streamable HTTP + SSE) | Tool definitions, protocol handling |
| `bandit` | HTTP server | Lightweight, no Phoenix needed |
| `plug` | HTTP middleware | Required by Anubis |
| `ecto_sql` + `postgrex` | Database access | Provided transitively by Arcana |
| `pgvector` | Vector type for Ecto | Provided transitively by Arcana |
| `oban` | Background jobs | Queues, uniqueness, custom backoff (core Oban) |
| `req` | HTTP client | URL scraping, OpenRouter API calls |
| `floki` | HTML parsing | Content extraction from scraped pages |
| `jason` | JSON encoding/decoding | Standard |
| `igniter` | Project scaffolding and code generation | Used during development |

## Optional / To Evaluate

| Package | Purpose | Notes |
|---------|---------|-------|
| `text_chunker` | Text chunking | Provided by Arcana, may use directly |
| `epub` or custom | Epub parsing | Need to evaluate available hex packages |
| `pdf_text` | PDF text extraction | Alternative to Arcana's poppler-based parser |

## Embedding Model

| Property | Value |
|----------|-------|
| Model | `qwen/qwen3-embedding-8b` |
| Provider | OpenRouter (served by Nebius) |
| Dimensions | 4096 |
| Cost | ~$0.00005 per chunk |
| Endpoint | OpenRouter embedding API |

## Custom Modules to Build

### `KB.Embedder.OpenRouter`

Implements `Arcana.Embedder` behaviour. Calls OpenRouter's embedding endpoint for qwen3-embedding-8b.

```elixir
defmodule KB.Embedder.OpenRouter do
  @behaviour Arcana.Embedder

  @impl true
  def embed(text, opts) do
    # Call OpenRouter embedding API
    # Return {:ok, vector} | {:error, reason}
  end

  # Optional Arcana.Embedder callback — batch embedding for efficiency
  @impl true
  def embed_batch(texts, opts) do
    # Batch embedding call
  end

  @impl true
  def dimensions(_opts), do: 4096
end
```

### `KB.Parsers.Epub`

Epub file parser — unzip, parse OPF spine, extract text from XHTML chapters.

### `KB.Sources`

Source context module — CRUD operations, dedup checks (URL match + content hash), tag queries. Wraps Ecto queries for the `sources` table.

### `KB.MCP.Tools.*`

One module per MCP tool, implementing Anubis's tool component interface.

### `KB.Search`

Custom search module for queries that go beyond Arcana's built-in `search/2`.
Contains: tag-filtered search (custom SQL joining `sources.tags` with `arcana_chunks` via `arcana_documents`),
and `find_related` (source centroid calculation + similarity search with source exclusion).
See [Search](search.md) for detailed algorithm descriptions.

## Arcana Configuration

Arcana must be configured with our custom embedder and chunking parameters. This lives in `config/config.exs`:

```elixir
config :arcana,
  repo: KB.Repo,
  embedder: KB.Embedder.OpenRouter,
  chunk_size: 450,       # tokens per chunk
  chunk_overlap: 50,     # overlap tokens between chunks
  vector_dimensions: 4096
```

### Wiring Details

- **Repo**: Arcana uses the same Ecto repo (`KB.Repo`) and Postgres instance as the rest of the app
- **Embedder**: Our `KB.Embedder.OpenRouter` module implements Arcana's `Embedder` behaviour
- **Collection**: If Arcana supports named collections, use a single collection `"kb"` (we separate concerns via our `sources` table, not Arcana collections)
- **Migrations**: Arcana provides its own migrations for `arcana_documents` and `arcana_chunks` tables. Run `mix arcana.install` to generate them, then run alongside the `sources` migration. Ensure your `sources.arcana_document_id` references Arcana's `arcana_documents.id`.
- **Schema Alignment**: Arcana's default install creates `arcana_chunks.embedding` as `vector(384)`. Our config requires `vector(4096)` for qwen3-embedding-8b. After running `mix arcana.install`, create a follow-up migration to alter the column type and recreate the HNSW index:
  ```sql
  ALTER TABLE arcana_chunks ALTER COLUMN embedding TYPE vector(4096);
  DROP INDEX IF EXISTS arcana_chunks_embedding_index;
  CREATE INDEX arcana_chunks_embedding_index ON arcana_chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 128);
  ```

### Oban Setup

Background jobs run on core Oban, pulled from the public hex repo in `mix.exs`:

```elixir
defp deps do
  [
    {:oban, "~> 2.24"},
    # ...
  ]
end
```

No license, private hex repo, or build-time credentials are needed. Queues
are declared statically in `config/config.exs`, and the schema is created by
the standard `Oban.Migration` migrations in `priv/repo/migrations/`.

## Infrastructure

| Component | Details |
|-----------|---------|
| **Server** | Self-hosted (existing) |
| **Database** | PostgreSQL 18 + pgvector extension (existing) |
| **Deployment** | Docker container |
| **Domain** | Private DNS name (Tailscale / LAN) |
| **Network** | Private (Tailscale / LAN) |
| **Port** | 4000 |

## Elixir / OTP Version

- Elixir: latest stable (1.18+)
- Erlang/OTP: 27+
- Use `.tool-versions` or `mise` for version management

## Project Structure

```
kb/
├── lib/
│   ├── kb/
│   │   ├── application.ex
│   │   ├── repo.ex
│   │   ├── router.ex                  (top-level Plug router, composes API + MCP)
│   │   ├── search.ex                  (tag-filtered search + find_related logic)
│   │   ├── embedder/
│   │   │   └── open_router.ex
│   │   ├── parsers/
│   │   │   ├── html.ex
│   │   │   └── epub.ex
│   │   ├── sources.ex               (source context)
│   │   ├── sources/
│   │   │   └── source.ex             (Ecto schema)
│   │   ├── workers/
│   │   │   ├── ingest_url.ex
│   │   │   └── ingest_content.ex
│   │   ├── api/
│   │   │   └── router.ex              (Plug router for HTTP API)
│   │   └── mcp/
│   │       ├── server.ex              (Anubis MCP server config)
│   │       └── tools/
│   │           ├── search_tool.ex
│   │           ├── ingest_url_tool.ex
│   │           ├── list_sources_tool.ex
│   │           ├── list_tags_tool.ex
│   │           ├── get_source_tool.ex
│   │           ├── get_chunks_tool.ex
│   │           ├── delete_source_tool.ex
│   │           ├── update_tags_tool.ex
│   │           └── find_related_tool.ex
│   └── kb.ex
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── prod.exs
│   ├── runtime.exs
│   └── test.exs
├── priv/
│   └── repo/
│       └── migrations/
├── test/
├── Dockerfile
├── docker-compose.yml
├── mix.exs
├── mix.lock
├── .formatter.exs
├── .env.example
└── SPECS.md
```

# Deployment

## Overview

KB runs as a Docker container on an existing host server, connecting to an existing PostgreSQL instance. It's exposed on the private network on port 4000.

## Docker

### Dockerfile

Multi-stage build:
1. **Build stage**: Compile Elixir release with `mix release`
2. **Runtime stage**: Minimal Debian/Alpine image with Erlang runtime only

Key considerations:
- Include poppler-utils (or equivalent) for PDF text extraction in the runtime image
- Include unzip capability for epub parsing

### docker-compose.yml

```yaml
services:
  kb:
    build: .
    ports:
      - "4000:4000"
    environment:
      - DATABASE_URL=ecto://user:pass@host/kb_prod
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
    restart: unless-stopped
```

PostgreSQL is **not** in the compose file — it's already running on the host server.

## Database

### Setup

1. Create database: `kb_dev` (local), `kb_prod` (server)
2. Enable pgvector extension: `CREATE EXTENSION IF NOT EXISTS vector`
3. Run Ecto migrations: `mix ecto.migrate` locally. On the server, the deploy tooling runs `KB.Release.migrate()` with the new image before it replaces the running container, so new code never starts against an old schema. Migrations must stay additive, since the old container keeps serving while they run.

### pgvector

pgvector must be installed in the PostgreSQL instance on the host server. If not already present, install via the OS package manager or compile from source.

## Network

- Service listens on `0.0.0.0:4000`
- Accessible only from private network (Tailscale / LAN)
- DNS: a private DNS name (e.g. `kb.lan`) → host server IP
- No TLS termination needed on the app (handle at reverse proxy if desired)

## Configuration

All runtime config via environment variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | Yes | PostgreSQL connection string |
| `OPENROUTER_API_KEY` | Yes | API key for embedding calls |
| `PORT` | No | HTTP port (default: 4000) |
| `SECRET_KEY_BASE` | Yes | Standard Elixir secret (for Oban encryption, etc.) |

## Health Check

A simple `GET /health` endpoint (via Plug) returning 200 OK. Used by Docker's healthcheck and monitoring.

## Backup

All embeddings cost money to regenerate (~$0.00005/chunk × thousands of chunks). A simple backup strategy:

### pg_dump Cron

```bash
# /etc/cron.d/kb-backup (on the host server)
0 3 * * * pg_dump -Fc kb_prod > /backups/kb/kb_prod_$(date +\%Y\%m\%d).dump
# Keep 30 days of daily backups
0 4 * * * find /backups/kb -name "*.dump" -mtime +30 -delete
```

### What's Backed Up

- `sources` table (metadata, tags, status)
- Arcana's `arcana_documents` and `arcana_chunks` tables (including embeddings)
- Recreating from scratch would require re-ingesting all content and re-embedding (~$0.01 per book, but time-consuming)

### Restore

```bash
pg_restore -d kb_prod /backups/kb/kb_prod_20250330.dump
```

## Model Migration

When switching embedding models (e.g., from qwen3-embedding-8b to a newer model):

1. **All existing embeddings become incompatible** — vectors from different models occupy different embedding spaces and cannot be compared
2. **Migration path**: Re-ingest all sources with the new model
   - Update `KB.Embedder.OpenRouter` to use the new model
   - If dimensions change, update `vector(4096)` column type and HNSW index
   - Delete all existing chunks (or create a new chunks table)
   - Re-run ingestion for every source (original text content is stored in `arcana_documents.content` by Arcana during ingestion, so re-embedding reads from there — no need to re-scrape URLs or re-upload files)
3. **Cost**: At ~$0.00005/chunk, re-embedding 10,000 chunks costs ~$0.50. Time is the bottleneck, not money.
4. **Consider**: Keep the old model config around until the new one is validated. Don't drop old chunks until new ones are verified.

## Monitoring

- **Oban Web**: Optional dashboard for job monitoring (requires a Plug route)
- **Telemetry**: Arcana emits telemetry events for ingest, search, embed operations
- **Logs**: Standard Elixir Logger output to stdout (Docker captures it)

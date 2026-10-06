# KB — Personal Knowledge Base

A self-hosted RAG-powered knowledge base with MCP search/management tools and an HTTP ingestion API for large payloads. Ingest books, articles, transcripts, and notes; search them semantically from Claude Code or any MCP client.

## Specs

| Spec | Description |
|------|-------------|
| [Overview](specs/overview.md) | Project goals, scope, non-goals, and definition of done |
| [Architecture](specs/architecture.md) | System diagram, design decisions, supervision tree, request flows |
| [Data Model](specs/data-model.md) | Database schema, indexes, chunking parameters |
| [Ingestion](specs/ingestion.md) | Content pipeline for URLs, PDFs, epubs, text, and transcripts |
| [Keyed Documents](specs/documents.md) | Collections, documents that update in place, sync, and the `kb sync` CLI |
| [Search & Retrieval](specs/search.md) | Keyword syntax, rank fusion, reranking, grouping, filters, latency |
| [MCP Tools](specs/mcp-tools.md) | Tool definitions for search, management, and URL ingestion |
| [HTTP API](specs/api.md) | REST endpoints for file upload and large text ingestion |
| [Tech Stack](specs/tech-stack.md) | Dependencies, custom modules, project structure |
| [Deployment](specs/deployment.md) | Docker, networking, configuration |

## Quick Reference

| | |
|---|---|
| **Stack** | Elixir + Arcana + Anubis MCP + Bandit + Oban + pgvector |
| **Embeddings** | qwen3-embedding-8b via OpenRouter (4096-dim) |
| **Search** | Hybrid (keyword + semantic, rank fusion, cross-encoder rerank) |
| **Deploy** | Docker on a self-hosted server |
| **Access** | MCP over Streamable HTTP on `:4000` |
| **Auth** | None (private network) |

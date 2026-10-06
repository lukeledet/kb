# Overview

## Project Name

**KB** — a personal knowledge base with MCP interface.

## Problem

Valuable knowledge is scattered across books, articles, videos, podcasts, and notes. When working with AI agents (Claude Code, etc.), this knowledge isn't available as context. You end up manually pasting excerpts or re-explaining concepts that you've already synthesized elsewhere.

## Solution

A self-hosted RAG system that ingests, chunks, embeds, and indexes content from multiple source types. Search and source management are exposed via MCP (Model Context Protocol), while large-payload ingestion is handled by a small HTTP API to avoid bloating the agent's context window.

## Goals

- **Synthesize knowledge**: Ingest books, articles, transcripts, and notes into a single searchable corpus
- **Agent-accessible**: Expose via MCP so Claude Code and other tools can query it naturally during work
- **Low friction**: Ingest a URL via MCP or upload a file/text document via HTTP, tagged and searchable immediately
- **Cheap to operate**: Use cost-effective embedding models (qwen3-embedding-8b via OpenRouter at ~$0.00005/chunk)
- **Self-hosted**: Runs on existing self-hosted infrastructure, no external dependencies beyond OpenRouter

## Non-Goals

- No web UI
- No multi-user support (single user)
- No LLM-powered synthesis within the KB itself (agents do their own reasoning over retrieved chunks)
- No auto-transcription (pre-made transcripts are ingested as text)
- No real-time collaboration or sharing features

## Users

- **Primary**: Claude Code MCP
- **Secondary**: Any MCP-compatible AI tool on the private network

## Content Domains (Initial)

- Product development methodology (e.g., Shape Up)
- System architecture patterns
- Productivity and workflow optimization
- Technical reference material
- General non-fiction books and articles

## What "Done" Looks Like (v1)

All MCP tools working end-to-end:
1. Ingest a URL via MCP and ingest PDFs, epubs, markdown, or transcripts via HTTP API
2. Content is chunked, embedded, and stored with tags
3. Search returns relevant chunks with similarity scores
4. Sources can be listed, inspected, deleted, and re-tagged
5. Related sources can be discovered via vector similarity
6. Deployed via Docker on a self-hosted server, accessible on a private network

## Cross-Cutting Rules

### Status Transitions

Canonical source status enum: `pending`, `processing`, `completed`, `failed`.

Valid transitions are:

- `pending` → `processing` → `completed`
- `pending` → `processing` → `failed`

Status is set by Oban workers during ingestion. Initial source creation always starts as `pending`.
There is no mechanism to transition back from `completed` or `failed` — except `force: true`
re-ingestion, which creates a NEW source.

### Deduplication

- URL sources are checked against `sources.url` using an exact match.
- File/text sources are checked against `sources.content_hash` using the SHA-256 of the raw content.
- If a duplicate is found and `force=false`, return the existing source and do NOT enqueue a new job.
- If a duplicate is found and `force=true`, delete the existing source and create a new one for full re-ingestion.
- HTTP API returns `200` with the existing source on a dedup hit; dedup is NOT an error.
- MCP tools return the existing source on a dedup hit; dedup is NOT an error.

### Force Semantics

The `force` parameter is accepted by `ingest_url` (MCP), `POST /api/ingest/file` (HTTP), and
`POST /api/ingest/text` (HTTP). Default is `false`.

When `true`, `force` bypasses the dedup check, deletes the existing source (and its Arcana document
plus chunks), creates a fresh source, and re-ingests.

Use `force: true` when content has changed at the same URL or when re-processing with different settings.

# KB

KB is a self-hosted knowledge base for AI tools. It ingests URLs, text, PDFs, and EPUBs, stores chunked embeddings in Postgres with pgvector, and exposes both an MCP interface and a small HTTP API.

## Stack

- Elixir 1.20.0-rc.4
- PostgreSQL + pgvector
- Oban for ingestion jobs
- OpenRouter for embeddings

## Local Development

1. Make sure PostgreSQL is running and the local `../oban_pro` dependency is available.
2. Install dependencies and set up the database:

```sh
mix setup
```

3. Set `OPENROUTER_API_KEY` in your shell when you need real embeddings.
4. Start the app:

```sh
iex -S mix
```

The service runs on `http://localhost:4000`.

## CLI

`bin/kb` is a small command-line client for the HTTP API. It sends URLs, local
PDFs/EPUBs, and text files to the KB and returns as soon as the work is queued,
printing the `kb status` command to check on it. Pass `--wait` to poll until
ingestion finishes instead.

```sh
kb ingest https://example.com/post --tags web,elixir
kb ingest ~/Downloads/book.epub --title "Some Book" --tags book
kb ingest notes.md --type transcript --tags notes
kb ingest ~/Downloads/book.epub --wait
kb status <source-id>
kb content <source-id> > book.txt
kb health
```

`kb sync` keeps a folder of documents, such as a markdown wiki, in step with a
collection. It uploads only new and changed files, renames moved ones without
re-indexing, and deletes documents whose files are gone. `--git-ref HEAD`
syncs what is committed rather than the working tree, which suits a git
post-commit hook:

```sh
kb sync ~/src/research --collection wiki --git-ref HEAD \
  --include 'sources/*.md,entities/*.md,concepts/*.md,analyses/*.md,overview.md'
kb doc wiki concepts/scrum.md
kb search "loop memory" --collection wiki --documents
kb links wiki concepts/comprehension-debt.md
kb context wiki sources/ "One summary page per raw source"
kb collection wiki
kb related wiki concepts/comprehension-debt.md --collection library
kb reindex wiki   # after a chunking change; kb relink wiki rebuilds links only
```

`kb stats` also shows how recent searches went: how many fell back and why,
latency, and each query-embedding backend's speed.

See `specs/documents.md` for how documents update in place.

The KB base URL defaults to `http://localhost:4000`; override it with the
`KB_URL` environment variable, `--url`, or a personal default in `~/.kbrc`
(which `kb` sources if present). It shells out to `curl` (not
node/bun) on purpose: macOS Local Network Privacy blocks LAN `fetch` from
node, while Apple-signed `curl` gets through. Requires `curl` and `jq`.

To put it on your `PATH`, symlink it: `ln -s "$PWD/bin/kb" /usr/local/bin/kb`.
Run `kb help` for the full option list.

## Interfaces

### HTTP API

- `GET /health`
- `POST /api/ingest/url` – ingest a URL
- `POST /api/ingest/file` – upload a PDF or EPUB
- `POST /api/ingest/text` – ingest raw text or transcript
- `GET /api/sources/:id` – check source status
- `GET /api/sources/:id/content` – get a source's full ingested text
- `PATCH /api/sources/:id` – update a source's `title` and/or `metadata`
- `/api/collections/...` – keyed documents: batch upsert, diff and prune,
  delete, rename, and reads by key or prefix (see `specs/documents.md`)

All three ingest endpoints accept an optional `metadata` JSON object stored on the
source (for example a link to the Hacker News thread). `PATCH` merges into the
stored map, so you can add one key without resending the rest; send a key as
`null` to drop it.

### MCP Tools (at `/mcp`)

- `search` – hybrid keyword and semantic search with reranking, filters,
  and one-result-per-document grouping (see `specs/search.md`)
- `ingest_url` – ingest a URL
- `list_sources` – list all sources
- `get_source` – get source details
- `delete_source` – remove a source
- `update_tags` – add/remove tags on a source
- `list_tags` – list all tags in use
- `get_chunks` – retrieve chunks for a source
- `find_related` – find sources related to a given one
- `get_document`, `multi_get`, `upsert_document`, `delete_document`,
  `collection_status` – read and manage keyed documents
- `backlinks`, `outlinks`, `link_report` – wikilinks between documents

Each tool is exposed under its module name, such as `search_tool`.

## More Info

Implementation notes and API details live in `specs/` and `SPECS.md`.

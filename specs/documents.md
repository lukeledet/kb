# Keyed Documents and Collections

## Overview

A keyed document is a source that the caller names and keeps in sync with an
outside copy, such as a markdown file in a git repository. The caller picks a
**collection** (for example `wiki`) and a **key**, which is usually the file's
path (for example `concepts/scrum.md`). Sending new text for the same key
replaces the document in place. Its id never changes.

Keyed documents exist so the research wiki can use the KB as its search tool.
The wiki changes in batches of 10 to 60 pages per commit. A git hook runs
`kb sync`, which uploads only what changed.

Every source belongs to exactly one collection. Sources ingested through the
original URL, file, and text endpoints have no key and live in the `library`
collection. Search covers every collection unless the caller filters to one.

The code lives in `KB.Documents`, `KB.Markdown`, `KB.Workers.SyncDocument`,
`KB.API.Collections`, and `bin/kb sync`.

## Data model

A keyed document is a row in `sources` with these columns set:

| Column | Meaning |
|---|---|
| `collection` | Collection name. Lowercase letters, digits, `-` and `_`, up to 64 characters. Defaults to `library`. |
| `key` | The caller's name for the document. A relative path: no leading `/`, no empty, `.` or `..` segments, no control characters or `\`. Unique within a collection. |
| `slug` | The key's file name, lowercased, without `.md`. Wikilinks resolve through it. |
| `frontmatter` | The page's YAML frontmatter, parsed into a JSON object. GIN-indexed for filters. |
| `content_hash` | SHA-256 hex of the latest text the caller sent, which may still be indexing. |
| `source_type` | `markdown` (the default for keyed documents), `text`, or `transcript`. |

Unique indexes:

- `(collection, key)` where `key IS NOT NULL`.
- `content_hash` where `content_hash IS NOT NULL AND key IS NULL`. Content-hash
  dedup applies to library sources only. Two keyed pages may hold the same
  text.

The `collections` table records per-collection state that no source row can
hold. Today that is `last_synced_at`: the last time a diff found nothing to
upload and nothing extra left. A sync that changes nothing touches no source,
so this can't be derived from `sources.updated_at`.

Each chunk of a markdown document stores its heading path in
`arcana_chunks.metadata["heading_path"]`, for example
`["Loop memory", "Details", "Common files"]`.

## Versions and the atomic swap

Each version of a document is identified by the SHA-256 of its exact bytes.
Search reaches chunks only through `sources.arcana_document_id`, and that
pointer is what makes replacing a document atomic.

1. **Upsert.** `KB.Documents.upsert/4` locks the row for `(collection, key)`.
   - No row: insert it with status `pending` and queue a job. Result:
     `created`.
   - Same hash, status `completed`: result `unchanged`. Nothing is queued.
   - Same hash, status `pending` or `processing`: result `pending`. The job is
     queued again; Oban's uniqueness folds it into the existing job, and
     replaces it if it was lost.
   - Same hash, status `failed`: queue again. Result: `retried`.
   - Different hash: set `content_hash` and status `pending`, and queue a
     job. The old version stays linked and searchable. Result: `updated`.
   - `force: true` queues the same hash again. Result: `updated`.
2. **Index.** `KB.Workers.SyncDocument` runs on the `sync` queue. It stops
   early if the document was deleted or newer text arrived. Otherwise it
   parses and chunks the text and embeds the chunks, without writing
   anything.
3. **Swap.** In one transaction:
   - Lock the source row. If it is gone, or its `content_hash` no longer
     matches the job's hash, roll back and cancel the job.
   - Insert the new Arcana document and its chunks.
   - Point the source at the new document, and set its title, tags,
     frontmatter, chunk count, and status `completed`.
   - Delete the old Arcana document. Its chunks cascade.

A reader sees the old version or the new one, never both and never neither.
A slow job for an old version can't overwrite a newer one, because the hash
check happens under the row lock.

The title, tags, and frontmatter describe the searchable version, so they
change at the swap, not at upsert. A new document gets them at upsert, since
it has no searchable version yet.

### Failures and retries

A failed attempt records the error and leaves the status `pending`. After
the fifth attempt the status becomes `failed`, and the old version, if any,
stays searchable. Retries back off 10, 20, 40, then 80 seconds. A diff
reports a failed document as `stale`, so the next sync sends it again.

### Freshness

Two things keep a small page's upsert fast:

- **Provider routing.** OpenRouter serves this model from several providers
  with very different latency. On 2026-09-29, Nebius answered a one-chunk
  request in about 0.5 s and DeepInfra in 1.7 to 9.7 s, with vectors that
  agree to a cosine of 0.9999. Every OpenRouter embedding request asks for
  the providers in `config :kb, :openrouter_provider_order` first (default
  `["nebius"]`), with fallbacks allowed.
- **Hedging.** A keyed document's embedding request that has not answered in
  2 seconds is sent a second time, and the first answer wins. The slower
  request is left to finish rather than killed, since killing requests
  mid-flight stalled Finch's connection pool.

The LAN embedder is no help for documents: it embeds a 450-token chunk in
about 30 seconds on CPU.

### The sync queue

Keyed documents index on their own `sync` queue (10 workers), separate from
`ingestion` (2 workers). A page edit never waits behind a book. The text
travels in the job's args rather than a temp file, because temp files do not
survive a redeploy. Keyed documents skip the auto-tagger. Their tags come from
the frontmatter plus any the caller passes.

## Markdown handling

`KB.Markdown` handles documents with `source_type: markdown`.

- **Frontmatter.** A leading `---` block is parsed as YAML into
  `frontmatter`. Keys become strings. Values JSON can't hold are stored as
  their printed form. Invalid YAML, or YAML that isn't a mapping, is dropped
  with a warning in the upsert response; the body is still indexed.
- **Title.** In order: the caller's `title`, the frontmatter `title`, the
  first `# ` heading outside a code block, then the key's file name.
- **Tags.** The caller's tags plus the frontmatter `tags`, which may be a YAML
  list or a comma- or space-separated string.
- **Chunks.** Frontmatter is left out of chunk text, and so are link lists:
  - A `## Sources` section, with its subsections, is dropped, since the
    frontmatter already lists its links.
  - A `## Related` or `## See also` section, and any section that is nothing
    but wikilinks (after list markers and short labels such as `Entities:`),
    is folded onto the end of the section before it. It never becomes a
    chunk of its own and doesn't count toward chunk size.

  What remains is one chunk if it fits in 1,800 characters (Arcana's
  450-token chunk). A longer body splits at headings outside fenced code:
  - A heading with no text of its own joins the section it opens, so a
    chunk never ends on a bare heading.
  - Small neighboring sections pack together, but never across a `#` or
    `##` heading. The one exception is a page's lead (the text above its
    first `##`), which joins the first section when both fit.
  - A section too big for one chunk is split by Arcana's chunker. Its
    headings go on the first piece and any folded links on the last.

  Each chunk's heading path is the part of the path that all its sections
  share, led by the page title: a chunk holding `### Criticisms` and
  `### The business around it` has the path `Scrum > Details`. Each chunk
  starts with that path as a breadcrumb line, unless it opens on the page's
  own title heading.
- **Empty pages.** An empty document is stored with text `""` and no chunks,
  so an empty file in a synced folder doesn't block every sync.
- **Stored text.** The Arcana document holds the exact bytes sent, including
  frontmatter, so a read returns them unchanged.

Sections are read by heading: `KB.Markdown.section/2` returns the section
under the first heading whose text matches (ignoring case), with its
subsections, up to the next heading at the same level or higher.

## Diff and prune

`KB.Documents.diff/3` compares a manifest of `{key, content_hash}` with a
collection:

| Field | Meaning |
|---|---|
| `missing` | In the manifest, not in the collection. |
| `stale` | In both with a different hash, or indexing failed. |
| `pending` | Same hash, still indexing. |
| `extra` | In the collection, not in the manifest. |
| `unchanged` | Count of keys with the same hash, indexed. |
| `renames` | `{from, to}` pairs: an extra key whose hash matches a missing key's. |
| `pruned` | Keys deleted by this call when `prune: true`. |

With `prune: true`, extra keys are deleted. A prune that would delete more
than 20% of the collection and more than 5 documents is refused unless
`force: true` is also passed. The guard stops a sync with a wrong include
pattern from emptying a collection.

## Wikilinks

`KB.Markdown.links/1` reads `[[target]]`, `[[target|alias]]`,
`[[target#heading]]`, embeds (`![[target]]`), and block references
(`[[target^block]]`) from a markdown document's whole text, frontmatter
included, skipping fenced code. A link to a heading on the same page
(`[[#heading]]`) has no target and is skipped.

Links are stored in the `links` table (`source_id`, `target` as written,
`target_slug`, `heading`, `alias`, `embed`, `position`) when a version is
swapped in, in the same transaction, so they always describe the
searchable text. Deleting a document deletes its links.

A link keeps its target as a slug, by the same rule as a document's `slug`
(file name without `.md`, lowercased), and is resolved when it is read, to
every document in the same collection with that slug:

- `ok`: one document.
- `broken`: none.
- `ambiguous`: several.

A page created or renamed later fixes the links to it without anything
being re-indexed. A renamed page's old slug no longer resolves, so links to
it show as broken until the linking pages are edited.

`KB.Links` answers:

- `backlinks(collection, slug)`: the pages linking to a slug, each once,
  with a count and the aliases and headings used.
- `outlinks(source)`: one entry per target and heading, in first-seen
  order, with its status and resolved documents.
- `report(collection)`: broken links by linking page, orphans (documents
  no other document links to; an ambiguous link counts for every page
  sharing the slug), ambiguous slugs, and complete counts. Each list is
  capped at 500 entries.
- `relink(collection)`: rebuilds every markdown document's links from its
  stored text, without embedding anything.

## Context notes

A context note says what a collection, or a key prefix within it, holds,
such as "one summary page per raw source" for the wiki's `sources/`. Notes
live in `collection_contexts` (`collection`, `prefix`, `description`, up to
500 characters); an empty prefix is the note for the whole collection.

Search results carry `context`, the list of every note that applies to the
result's collection and key, the collection's first and the longest prefix
last. Chunk results carry it on `source.context`. `get_document` includes it
too, and collection status lists a collection's notes. A result with no
applicable note has no `context` field.

## HTTP API

All endpoints live under `/api/collections`. Keys contain slashes, so they
travel in JSON bodies and query strings, never in the URL path.

| Method and path | Body or query | Returns |
|---|---|---|
| `GET /api/collections` | | `{collections: [{name, documents}]}` |
| `GET /api/collections/:c` | | Status: `documents`, `by_status`, `pending`, `chunks`, `failed` (key and error, up to 50), `last_changed_at`, `last_synced_at` |
| `POST /api/collections/:c/diff` | `{manifest: [{key, content_hash}], prune?, force?}` | The diff above. 409 when the prune guard refuses. |
| `POST /api/collections/:c/documents` | `{documents: [{key, content, title?, tags?, metadata?, source_type?}], force?, wait?, timeout?}` | `{results: [{key, id, result, status, title, content_hash, warnings?, error?}], counts, errors}` |
| `GET /api/collections/:c/documents` | `?key=...&section=...` | The document with `content`, `content_hash`, and `pending` |
| `POST /api/collections/:c/documents/get` | `{keys}` or `{prefix}`, `limit?` (default 50, max 500), `include_content?` | `{documents, missing, truncated}` |
| `POST /api/collections/:c/delete` | `{keys}` | `{deleted, not_found}` |
| `POST /api/collections/:c/rename` | `{from, to}` | The document. 404 if `from` is missing, 409 if `to` is taken. |
| `POST /api/collections/:c/reindex` | | 202 with `{queued}`. Re-chunks and re-embeds every indexed document from its stored text, keeping ids, titles, tags and metadata. For when chunking rules change. |
| `DELETE /api/collections/:c` | | Forgets an empty collection, including its last sync time. 409 while it has documents, 404 if unknown. |
| `GET /api/collections/:c/links` | `?key=...` or `?slug=...` | `{slug, document, backlinks, outlinks}`. A slug works for a page that doesn't exist; `document` is then null and `outlinks` empty. |
| `GET /api/collections/:c/link_report` | | `{counts, broken, orphans, ambiguous}` |
| `POST /api/collections/:c/relink` | | `{relinked}`: rebuilds links from stored text |
| `GET /api/collections/:c/contexts` | | `{contexts: [{prefix, description, updated_at}]}` |
| `PUT /api/collections/:c/contexts` | `{prefix, description}` | Sets a note. An empty or null description removes it. |
| `GET /api/sources/:id/related` | `?collection=...&limit=...` | `find_related`, optionally only sources in one collection (limit default 5, max 50) |

Notes:

- A batch upsert takes up to 500 documents. Each document succeeds or fails
  on its own; `errors` counts the failures.
- `wait: true` blocks until every queued document is indexed, fails, or is
  superseded, or until `timeout` seconds pass (default 60, max 120). Each
  result's `status` is then the final state.
- `content_hash` in a read is the hash of the version served. `pending: true`
  means newer text is still indexing and the served text is the version that
  is searchable now.
- `POST /api/ingest/text` with `collection` and `key` upserts one document
  and accepts `wait`. It returns 202 when work was queued and 200 otherwise.

## MCP tools

| Tool | Does |
|---|---|
| `get_document_tool` | Reads a document by `collection` and `key`, or by `id`, optionally one `section`. Text over 200 KB is cut and marked `truncated`. |
| `multi_get_tool` | Reads documents by `keys` or `prefix`. Default limit 20. Stops adding text past 200 KB and marks the reply `truncated`. |
| `upsert_document_tool` | Creates or replaces a document up to 1 MB. `wait: true` waits up to 20 seconds. |
| `delete_document_tool` | Deletes a document by `collection` and `key`. |
| `collection_status_tool` | Status for one collection, including its context notes, or the list of collections. |
| `backlinks_tool` | Pages linking to a page, by `key` or `slug`. |
| `outlinks_tool` | A page's links, each resolved: ok, broken, or ambiguous. |
| `link_report_tool` | A collection's broken links, orphans and ambiguous slugs. |

`find_related_tool` takes a `collection`, so a wiki page can find the raw
sources closest to it. `search_tool` takes a `collection` filter. Every search result's `source`
carries `collection` and `key`. `list_sources_tool` takes a `collection`
filter, and `get_source_tool` returns `collection`, `key`, and `frontmatter`.

## The `kb sync` CLI

```sh
kb sync <dir> --collection <name> [--include <globs>] [--exclude <globs>]
        [--git-ref <ref>] [--no-prune] [--force] [--dry-run] [--timeout <secs>]
```

1. Takes a per-collection lock in `$TMPDIR`, waiting up to `--timeout`. The
   lock is taken before `--git-ref` is resolved, so when two commits fire
   hooks in quick succession, the later sync reads the later commit.
2. Lists files. With `--git-ref`, it reads the blobs committed at that ref
   with `git cat-file`: no smudge filters, no line-ending changes, and no
   uncommitted or untracked files. Symlinks and submodules are skipped.
   Without it, it reads the working tree and skips `.git`.
3. Keys are paths relative to `<dir>`. In `--include` and `--exclude`, `*`
   and `?` stay within one folder, `**` crosses folders, and every other
   character is literal. The default include is `**/*.md`. Matching no files
   is an error.
4. Hashes every file with `shasum -a 256`, sends the manifest to `diff`, and
   prints the plan. `--dry-run` stops here.
5. Applies suggested renames, which carry indexed text over without
   embedding it again. It skips them with `--no-prune`, which must keep the
   old key.
6. Uploads missing and stale files in batches of up to 50 files or about
   1 MB. Pending files already have their text queued, so they are waited
   on, not sent again. Files that are not valid UTF-8 are refused, since JSON would
   rewrite them and their hash would never match.
7. Polls `diff` until nothing is pending, then runs a final diff with
   `prune`. It gives up when the pending count has not dropped for
   `--timeout` seconds, so a large first sync keeps going as long as it
   makes progress.
8. Prints `created N, updated N, renamed N, deleted N, pending N, unchanged N`,
   where pending counts files that were already indexing when the sync
   started. It exits
   non-zero unless the final diff shows nothing missing, stale, pending, or
   (when pruning) extra.

`kb collection [name]` lists collections or shows one's status, including
its context notes and failed documents. `kb related <id>` or `kb related
<collection> <key>` lists the sources closest in meaning, with
`--collection` to keep to one collection. `kb reindex <collection>` and
`kb relink <collection>` call the reindex and relink endpoints.

`kb links <collection> <key>` prints a page's backlinks and outlinks, and
`kb links <collection> --report` the collection's link report. `kb context
<collection> [prefix] [description]` lists, sets or clears (empty
description) context notes.

`kb doc <collection> <key> [--section <heading>]` prints a document's stored
text with no added newline, so `kb doc wiki a.md | cmp - a.md` checks it byte
for byte.

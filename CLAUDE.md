# CLAUDE.md

## Deploy

KB runs as a Docker container on a remote host, reached over SSH. The code at
the remote source tree is **not** a git checkout — deploying means pushing the
committed `HEAD` from this repo, then rebuilding.

Deployment is driven by tooling that lives **outside this repo** (a private
deploy script plus `~/.kbrc`, which holds the SSH alias, container id, and KB
URL). The flow: archive the committed `HEAD`, push it onto the remote source
tree, build the release image, run pending migrations with the new image,
recreate the container, and poll `/health` until it returns green.

Notes:
- Migrations run while the old container still serves, so keep them additive.
- Only committed code is deployed; uncommitted changes are skipped (with a warning).
- Runtime secrets (`DATABASE_URL`, `OPENROUTER_API_KEY`, `SECRET_KEY_BASE`) live in
  the remote `.env` file, not in git.
- The image only includes `lib/`, `config/`, `priv/`, and the mix files (see
  `Dockerfile` / `.dockerignore`); `bin/` holds the `kb` client, not part of
  the server.

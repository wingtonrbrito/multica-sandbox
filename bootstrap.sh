#!/usr/bin/env bash
# bootstrap.sh — clone both forks (customizations branches) and bring the
# Multica self-host platform up to a healthy state. Stops short of creating
# any agents/skills/autopilots — those need workspace-specific config and are
# covered in docs/01-quickstart.md steps 5–8.
#
# Run from the directory where you want the two checkouts to live side-by-side
# (e.g., ~/projects). Both forks land at the same level in subdirectories:
#
#   <cwd>/multica/                  — Multica core (our fork, customizations branch)
#   <cwd>/huly-mcp-server/          — Huly MCP server (our fork, customizations branch)
#
# Idempotent: re-running will pull-and-rebuild rather than re-clone.

set -euo pipefail

MULTICA_REPO="https://github.com/wingtonrbrito/multica"
HULY_MCP_REPO="https://github.com/wingtonrbrito/huly-mcp-server"
BRANCH="wingtonrbrito-customizations"

color() { printf '\033[1;36m%s\033[0m\n' "$1"; }
warn()  { printf '\033[1;33m%s\033[0m\n' "$1"; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required tool '$1' not found in PATH." >&2
    echo "Install it and retry." >&2
    exit 1
  fi
}

# --- pre-flight ---------------------------------------------------------

color "==> Pre-flight checks"
require git
require docker
require node
require make

# Optional but recommended
for t in multica gh jq; do
  if ! command -v "$t" >/dev/null 2>&1; then
    warn "  (optional) '$t' not on PATH — you'll need it for later steps"
  fi
done

# --- multica core fork --------------------------------------------------

color "==> Multica core fork"
if [[ -d multica/.git ]]; then
  echo "  multica/ already exists — updating in place"
  cd multica
  git fetch origin --quiet
  git checkout "$BRANCH"
  git pull --ff-only origin "$BRANCH"
  cd ..
else
  git clone "$MULTICA_REPO" multica
  cd multica
  git checkout "$BRANCH"
  cd ..
fi

if [[ ! -f multica/.env ]]; then
  echo "  Creating multica/.env from .env.example"
  cp multica/.env.example multica/.env
  warn "  Edit multica/.env to taste before continuing (set APP_ENV=development for the dev master code 888888)."
fi

# --- huly-mcp-server fork ----------------------------------------------

color "==> Huly MCP server fork"
if [[ -d huly-mcp-server/.git ]]; then
  echo "  huly-mcp-server/ already exists — updating in place"
  cd huly-mcp-server
  git fetch origin --quiet
  git checkout "$BRANCH"
  git pull --ff-only origin "$BRANCH"
  cd ..
else
  git clone "$HULY_MCP_REPO" huly-mcp-server
  cd huly-mcp-server
  git checkout "$BRANCH"
  cd ..
fi

color "==> Installing huly-mcp-server deps"
( cd huly-mcp-server && npm install --silent )

# --- platform up --------------------------------------------------------

color "==> Bringing the Multica self-host platform up (this can take a few minutes the first time)"
echo "  (running 'make dev' from multica/ — installs deps, starts DB, migrates, launches services)"
echo
( cd multica && make dev ) &
MAKE_DEV_PID=$!

# --- summary -----------------------------------------------------------

cat <<EOS

------------------------------------------------------------------------
Bootstrap underway. While 'make dev' finishes building, here's what's next:

1. Wait for these URLs to come up:
     - Frontend: http://localhost:3000
     - Backend:  http://localhost:8080
   Log in with master code 888888 (if APP_ENV=development).

2. In a new terminal:
     brew install multica-ai/tap/multica
     multica setup self-host
     multica daemon start
     multica daemon status        # should say "running"

3. Smoke-test with the echo agent (see docs/01-quickstart.md step 5).

4. Wire the Huly MCP server. From this directory:
     export HULY_URL=https://your-huly-host
     export HULY_EMAIL=...
     export HULY_PASSWORD=...
     export HULY_WORKSPACE=...
     node huly-mcp-server/launch.mjs       # smoke-test only; Ctrl-C to stop

5. Build / clone the round-trip agents + skills + autopilots
   (docs/01-quickstart.md steps 7–8).

The 'make dev' process is now running in the foreground (PID $MAKE_DEV_PID).
Ctrl-C to stop it when you're done.
------------------------------------------------------------------------

EOS

wait "$MAKE_DEV_PID"

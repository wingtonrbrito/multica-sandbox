# 01 — Quick Start

Get from zero to a working multi-agent chain on your machine in ~30 minutes. This goes deeper than the upstream README: opinionated paths through every gotcha I hit.

## Prerequisites

| Tool | Version I tested | Notes |
|---|---|---|
| Docker Desktop | 28.5 | Self-host backend + postgres + frontend run as containers |
| `gh` CLI | 2.x | For agent → GitHub auth + PR creation |
| `git` | 2.x | Comes with Xcode CLT on macOS |
| `multica` CLI | 0.2.13 | Install via `brew install multica-ai/tap/multica` |
| `jq` | any | Half the recipes here pipe JSON through it |
| Claude Code (or Codex / Gemini) installed locally | latest | The actual agent runtime; daemon spawns this |

The Multica daemon itself is a single Go binary — see CLI install via the upstream tap.

---

## Step 1 — Run the self-host backend

```bash
git clone https://github.com/multica-ai/multica
cd multica
cp .env.example .env       # then edit: set APP_ENV=development for the dev master code 888888
make selfhost              # spins up postgres + backend + frontend in Docker
```

Three containers come up:

```
multica-postgres-1    healthy
multica-backend-1     up
multica-frontend-1    up
```

URLs:
- Frontend (UI): http://localhost:3000
- Backend (API): http://localhost:8080

Log in with the dev master code `888888` if you set `APP_ENV=development`. Otherwise configure `RESEND_API_KEY` for email codes.

## Step 2 — Auth the CLI

```bash
brew install multica-ai/tap/multica
multica setup self-host
```

This walks you through registering a personal access token + selecting your local workspace. Verifies with:

```bash
multica workspace list           # should show your workspace
multica agent list               # likely empty — that's fine
multica runtime list             # ditto
```

## Step 3 — Start the daemon

```bash
multica daemon start
multica daemon status            # should say "running" with a pid
```

The daemon polls the backend every 3s for assigned tasks and spawns the right agent CLI (`claude` / `codex` / `gemini`) per agent's runtime config.

You should see your runtimes registered:

```bash
multica runtime list
# NAME                          PROVIDER  STATUS
# Claude (your-machine.local)   claude    online
# Gemini (your-machine.local)   gemini    online
```

If `claude` runtime is missing, install Claude Code (`npm i -g @anthropics/claude-code`) and restart the daemon.

## Step 4 — Create an agent

The lightest possible agent: replies to its assigned issue with a comment, then closes it.

```bash
RUNTIME_ID=$(multica runtime list --output json | jq -r '.[]|select(.provider=="claude")|.id')

multica agent create \
  --name "echo" \
  --description "Posts back what was in the issue, then closes it" \
  --runtime-id "$RUNTIME_ID" \
  --model "claude-sonnet-4-6" \
  --visibility workspace \
  --instructions "On every wake, run: \`multica issue get <ASSIGNED_ID> --output json\`. If status is already done/cancelled, exit silently. Otherwise post one comment via \`multica issue comment add <ID> --content \"acknowledged: <issue title>\"\`, then \`multica issue status <ID> done\`."
```

## Step 5 — Fire your first issue

```bash
ID=$(multica issue create \
  --title "Smoke test from the sandbox" \
  --description "Just say hi" \
  --assignee echo \
  --output json | jq -r '.id')

echo "watch: http://localhost:3000/aipex-ws/issues/$ID"
```

Open the URL. Within ~10 seconds you'll see the assignee badge change to "echo" → status flip to `in_progress` → a comment from the agent → status flip to `done`. ~30 seconds end-to-end.

## Step 6 — Inspect what happened

```bash
multica issue get $ID                       # current state
multica issue comment list $ID              # all comments
multica issue runs $ID                      # agent invocations + lifecycle
```

For richer visualization see [`scripts/multica-trace-issue.py`](../scripts/multica-trace-issue.py) — renders the full chain (parent + descendants) as a single timeline.

## Step 7 (optional) — A real multi-agent chain

The fun starts with two agents handing work to each other. See [`docs/04-state-machine.md`](04-state-machine.md) and [`scenarios/01-simple-endpoint.md`](../scenarios/01-simple-endpoint.md) for the canonical orchestrator → engineer → qa-review pattern.

---

## Common first-run problems

| Symptom | Fix |
|---|---|
| Issue stays `todo`, agent never wakes | `multica daemon status` — daemon may have crashed; check `~/.multica/daemon.log` |
| Daemon "running" but no work happens | Backend connectivity broken — `docker ps` to check containers |
| `git push` fails inside the agent | Repo's git remote uses HTTPS but `gh` not auth'd in that account, or SSH alias not configured |
| Agent commits show wrong author | Set repo-local `user.name` / `user.email` (see [findings](07-findings.md#git-config-trap)) |
| Sub-issue created but specialist doesn't wake | Specialist not assigned yet; check the orchestrator's `create-sub-issue-safely` pattern |

If something else breaks, [`docs/02-cheatsheet.md`](02-cheatsheet.md) has commands for inspecting every layer.

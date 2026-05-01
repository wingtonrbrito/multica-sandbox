# 01 — Quick Start

Get from zero to a working multi-agent chain on your machine in ~30 minutes — using the **fork** with all open-PR patches included so you don't have to wait on upstream merges.

For one-shot mechanical setup, see [`bootstrap.sh`](../bootstrap.sh) in the repo root — it handles steps 1–4 below in one go.

## Prerequisites

| Tool | Version I tested | Notes |
|---|---|---|
| Docker Desktop | 28.5 | Self-host backend + postgres run as containers |
| Node.js | 22.x | Required by upstream Multica AND by the Huly MCP server |
| Go | 1.26.1 | For building the Multica server from source (the fork's `make dev` does this) |
| `gh` CLI | 2.x | Agent → GitHub auth + PR creation |
| `git` | 2.x | Comes with Xcode CLT on macOS |
| `multica` CLI | 0.2.13+ | `brew install multica-ai/tap/multica` |
| `jq` | any | Half the recipes here pipe JSON through it |
| Claude Code (or Codex / Gemini) installed locally | latest | The actual agent runtime; daemon spawns this |

## Step 1 — Clone the Multica fork (customizations branch)

We use the fork — not upstream — so you get our two open-PR patches (`--to` flag for `issue status`, daemon backend connectivity) without waiting on upstream merges.

```bash
git clone https://github.com/wingtonrbrito/multica
cd multica
git checkout wingtonrbrito-customizations
cp .env.example .env       # then edit: APP_ENV=development for the dev master code 888888
```

If you'd rather run pure upstream for comparison, clone `multica-ai/multica` instead. Same setup steps below.

## Step 2 — Boot the self-host platform from source

```bash
make dev
```

`make dev` auto-creates env, installs deps, starts a shared PostgreSQL container, runs migrations, and launches the backend + frontend.

URLs:
- Frontend (UI): http://localhost:3000
- Backend (API): http://localhost:8080

Log in with the dev master code `888888` if you set `APP_ENV=development`. Otherwise configure `RESEND_API_KEY` for email codes.

## Step 3 — Auth the CLI

```bash
brew install multica-ai/tap/multica
multica setup self-host
```

Walks you through registering a personal access token + selecting your local workspace. Verify:

```bash
multica workspace list
multica agent list           # likely empty — that's fine
multica runtime list         # ditto
```

## Step 4 — Start the daemon

```bash
multica daemon start
multica daemon status        # "running" with a pid
multica runtime list         # should now show Claude/Codex/Gemini runtimes online
```

The daemon polls the backend every 3s for assigned tasks and spawns the right agent CLI per agent's runtime config.

If `claude` runtime is missing, install Claude Code (`npm i -g @anthropics/claude-code`) and restart the daemon.

## Step 5 — Smoke-test with an echo agent

Sanity check the platform end-to-end before adding Huly. The lightest possible agent: replies to its assigned issue and closes it.

```bash
RUNTIME_ID=$(multica runtime list --output json | jq -r '.[]|select(.provider=="claude")|.id')

multica agent create \
  --name "echo" \
  --description "Posts back what was in the issue, then closes it" \
  --runtime-id "$RUNTIME_ID" \
  --model "claude-sonnet-4-6" \
  --visibility workspace \
  --instructions "On every wake, run: \`multica issue get <ASSIGNED_ID> --output json\`. If status is already done/cancelled, exit silently. Otherwise post one comment via \`multica issue comment add <ID> --content \"acknowledged: <issue title>\"\`, then \`multica issue status <ID> done\`."

ID=$(multica issue create \
  --title "Smoke test from the sandbox" \
  --description "Just say hi" \
  --assignee echo \
  --output json | jq -r '.id')

echo "watch: http://localhost:3000/<your-workspace-slug>/issues/$ID"
```

Within ~10 seconds the assignee badge changes to "echo" → status flips to `in_progress` → comment appears → status flips to `done`. ~30 seconds end-to-end.

If this works, the platform is healthy. If not, see "Common first-run problems" at the bottom.

## Step 6 — Wire the Huly MCP server

For the full Huly ↔ Multica ↔ GitHub round trip, you need the Huly MCP server bridging Multica skills to a Huly workspace. We use **our fork's customizations branch** so you get our three open-PR patches (Node polyfill, `add_comment` + `list_issue_relations`, `assignee` param) included.

```bash
cd ..       # back to your projects dir
git clone https://github.com/wingtonrbrito/huly-mcp-server
cd huly-mcp-server
git checkout wingtonrbrito-customizations
npm install

# Set Huly env vars (your Huly workspace credentials)
export HULY_URL=https://your-huly-host
export HULY_EMAIL=...
export HULY_PASSWORD=...
export HULY_WORKSPACE=...

# Smoke-test the MCP boots and connects
node launch.mjs       # should connect; Ctrl-C to stop
```

Wire it into Multica via your runtime's MCP config. For Claude Code as the runtime, the agent's `mcp_config` field on the Multica side points at:

```jsonc
{
  "mcpServers": {
    "huly": {
      "command": "node",
      "args": ["/absolute/path/to/huly-mcp-server/launch.mjs"],
      "env": {
        "HULY_URL": "...",
        "HULY_EMAIL": "...",
        "HULY_PASSWORD": "...",
        "HULY_WORKSPACE": "..."
      }
    }
  }
}
```

The agents that need Huly access (orchestrator with `huly-scan` / `huly-writeback` skills) attach this MCP config. Agents that don't need it leave their `mcp_config` empty.

## Step 7 — Build the round-trip agents and skills

For a full `Huly Backlog → Multica chain → GitHub PR → Huly Todo + Reviewer reassignment` round trip, you need:

- **Agents:** orchestrator, engineer, qa-review (minimum); analysts + synthesizer for fan-out
- **Skills:** `huly-scan` (read Backlog issues), `huly-writeback` (flip status + reassign at CLOSE), plus the regular `feature-implementation` / `qa-review` skills
- **Autopilots:** `Huly Scan` (periodic ingest), optionally `Orchestrator Sweep` (recovery audit)

Two paths:

**Build it up by hand** — follow the scenarios in order:
1. [`scenarios/01-simple-endpoint.md`](../scenarios/01-simple-endpoint.md) — orchestrator → engineer → qa-review chain on a non-Huly issue
2. [`scenarios/04-fan-out-multi-analyst.md`](../scenarios/04-fan-out-multi-analyst.md) — adds analysts + synthesizer
3. Wire `huly-scan` / `huly-writeback` skills onto the orchestrator (ask Wington for the current skill content; David's published version is in upstream DD-Demo)

**Clone from a snapshot** — if you have access to a snapshot of agents/skills/autopilots in the JSON shape Multica's API returns:
```bash
python3 path/to/multica-clone-from-snapshot.py path/to/snapshot/
```
The script in `ds-suite/ds-org-suite/scripts/multica-clone-david.py` is the reference — it reads David's snapshot, maps runtime IDs, and applies via API. Adapt the `--source` path to whatever snapshot you have.

## Step 8 — Run a round-trip end-to-end

Once agents + skills + autopilots are in place:

1. **File a Huly issue** in `Backlog` status, with a `Reviewer: <email>` line in the description.
2. **Trigger Huly Scan:**
   ```bash
   SCAN_ID=$(multica autopilot list --output json | python3 -c "
   import json,sys
   for a in json.load(sys.stdin).get('autopilots',[]):
       if a.get('title') == 'Huly Scan': print(a.get('id'))")
   multica autopilot trigger "$SCAN_ID"
   ```
3. **Watch the chain run.** A Multica parent gets created with `Huly: <id>` + `Reviewer: <email>` shape, orchestrator dispatches engineer → engineer opens a PR → QA Review approves → CLOSE flips Huly to Todo + reassigns to the Reviewer.

Detailed runbook (with edge cases, expected outputs, troubleshooting):
- Internal full version: `ds-suite/ds-org-suite/docs/multica/04-roundtrip-test.md`
- Public sketch: covered by [`scenarios/04-fan-out-multi-analyst.md`](../scenarios/04-fan-out-multi-analyst.md) + [`scenarios/06-edge-cases.md`](../scenarios/06-edge-cases.md) (E9 specifically tests Reviewer regex forms).

## Step 9 — Edge-case probes

When the daemon is up and you want to stress the post-adoption design (3-form Reviewer regex, concurrent autopilot purge, race-tight pre-check on SYNTHESIZE-MULTI), run:

```bash
~/projects/ds-suite/ds-org-suite/scripts/run-edge-cases.sh        # all three
~/projects/ds-suite/ds-org-suite/scripts/run-edge-cases.sh E9     # just one
```

Bails out cleanly if the daemon's stopped. Each scenario has explicit pass criteria the script reports.

## Step 10 — Inspect what happened

```bash
multica issue get $ID
multica issue comment list $ID
multica issue runs $ID
```

For richer visualization see [`scripts/multica-trace-issue.py`](../scripts/multica-trace-issue.py) — renders the full chain as a single timeline.

---

## Common first-run problems

| Symptom | Fix |
|---|---|
| Issue stays `todo`, agent never wakes | `multica daemon status` — daemon may have crashed; check `~/.multica/daemon.log` |
| Daemon "running" but no work happens | Backend connectivity broken — `docker ps` to check containers; new in our fork: `multica daemon status` will surface this directly via the `Backend:` line (PR #1910) |
| `git push` fails inside the agent | Repo's git remote uses HTTPS but `gh` not auth'd in that account, or SSH alias not configured |
| Agent commits show wrong author | Set repo-local `user.name` / `user.email` (see [findings](07-findings.md#git-config-trap)) |
| Sub-issue created but specialist doesn't wake | Specialist not assigned yet; check the orchestrator's `create-sub-issue-safely` pattern |
| `multica issue status <id> --to <s>` fails on stock upstream | Use the fork — PR #1805 added `--to` flag; upstream still requires positional form |
| Huly assignee never changes at CLOSE despite status flipping | Use the huly-mcp fork's customizations branch — PR #4 fixes this; stock `kwhittenberger/huly-mcp-server` doesn't accept `assignee` on `update_issue` |

If something else breaks, [`docs/02-cheatsheet.md`](02-cheatsheet.md) has commands for inspecting every layer.

---

## What you have now

After this quickstart:
- Multica self-host running from source with our two open-PR patches
- Huly MCP server bridging to your Huly workspace, with our three open-PR patches
- Echo agent verified end-to-end
- Agents + skills + autopilots wired (or pointed at the recipes to build them)
- Round-trip test pattern documented and runnable

You've effectively reconstructed the working version of the platform without waiting on a single upstream merge.

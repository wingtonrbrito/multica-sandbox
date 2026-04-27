# Scenario 01 — Simple endpoint, single specialist (engineer + QA)

The canonical "Multica works on my machine" smoke test. Hit DISPATCH → ADVANCE → CLOSE end-to-end with real GitHub artifacts in ~6 minutes.

## Setup (one-time)

You need 7 agents in your workspace plus their attached skills:
- `orchestrator` — hub, runs the state machine
- `engineer` — implements code, opens PRs
- `qa-review` — reviews PRs, verdict approve/needs-revision
- `arch-analyst`, `security-analyst`, `data-analyst`, `synthesizer` — not used in this scenario but worth having for FAN-OUT later

Plus a sandbox GitHub repo:
```bash
gh repo create <your-handle>/multica-sandbox --public --clone --add-readme
cd multica-sandbox
git config user.name "<your name>"      # repo-local, NOT global
git config user.email "<your email>"
git remote set-url origin git@github.com:<your-handle>/multica-sandbox.git  # SSH preferred
```

## The issue

```bash
multica issue create \
  --title "Add GET /api/hello endpoint to multica-sandbox" \
  --assignee orchestrator \
  --priority medium \
  --description "Add a GET /api/hello endpoint.

Target repo: /absolute/path/to/your/multica-sandbox
Remote: origin
Base branch: main

Response: 200 with JSON body {\"hello\": \"world\", \"timestamp\": <ISO8601 string>}.

Acceptance criteria:
* New file at app/api/hello/route.ts
* Content-Type: application/json
* No other files modified

Non-goals: no tests, no middleware changes."
```

## Watch it

```bash
./scripts/multica-watch.sh    # second terminal
```

## Expected events (~6 minutes)

```
00:00  ISSUE+   parent created, → orchestrator (todo)
00:23  STATUS   parent: todo → in_progress
00:45  ISSUE+   [engineer] sub-issue created, → - (parent assigned without)
00:51  REASSIGN [engineer] sub-issue: - → engineer
00:51  RUN      engineer DISPATCH,START
00:57  COMMENT+ on parent: "Dispatched to engineer"
01:00  RUN      orchestrator FINISH
02:13  STATUS   [engineer] sub-issue: in_progress → todo  (engineer done, reset before reassign)
02:13  REASSIGN [engineer] → orchestrator
02:13  COMMENT+ on engineer sub-issue: "Created `app/api/hello/route.ts`...PR: ..."
03:14  STATUS   [engineer] sub-issue: todo → done
03:14  COMMENT+ on parent: "Engineer handed back PR ... — advancing"
03:31  ISSUE+   [qa-review] sub-issue created
03:37  REASSIGN [qa-review] → QA Review
03:37  RUN      qa-review DISPATCH,START
04:40  COMMENT+ on qa-review: "Verdict: approved..."
04:46  STATUS   qa-review: in_progress → todo
04:51  REASSIGN qa-review → orchestrator
05:30  COMMENT+ on parent: "Chain complete — qa-review approved"
05:42  STATUS   parent → done
05:42  STATUS   qa-review → done
```

## Real artifacts

- A GitHub PR opens on your sandbox repo
- The PR has the engineer's commit signed under your local git identity
- QA Review's verdict comment is in the qa-review sub-issue's thread
- The orchestrator's narrative is on the parent (DISPATCH, ADVANCE, CLOSE comments)

## Trace

After completion:
```bash
./scripts/multica-trace-issue.py <parent-id>
```

## What this proves

- Daemon dispatches reliably to local runtime
- Engineer can clone repo, branch, write code, push, and open a PR (gh CLI auth + git config working)
- JSON contract handoff parses cleanly
- ADVANCE state transition works (engineer → qa-review)
- QA Review can read a PR diff and emit a structured verdict
- CLOSE flips parent + sub-issue to done
- All in one ~6 minute chain

## What this does NOT prove

- REVISE loop (Sonnet 4.6 nails simple specs first try; see [`03-revise-loop-recipe.md`](03-revise-loop-recipe.md))
- FAN-OUT multi-analyst (see [`04-fan-out-multi-analyst.md`](04-fan-out-multi-analyst.md))
- Skill scoping behavior (see [`05-skill-mutation.md`](05-skill-mutation.md))
- Edge cases (see [`06-edge-cases.md`](06-edge-cases.md))

## Common failure modes

| Symptom | Diagnosis |
|---|---|
| Issue stays `todo`, agent never wakes | `multica daemon status` — daemon likely down or backend unreachable |
| Engineer crashes on boot | `custom_args` references a Windows `C:/...` MCP config path that doesn't exist on macOS |
| `git push` fails | gh CLI not authenticated for the right account, OR SSH alias not configured |
| Engineer's commits show wrong author | Repo-local `user.name`/`user.email` not set; falls through to global |
| QA returns `blocked` claiming empty description | Read-after-write race; reassign manually to retry |
| Chain hangs after QA's comment | QA forgot to reassign back to orchestrator |

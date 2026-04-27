# multica-sandbox

A hands-on research log of running [Multica](https://github.com/multica-ai/multica) agents end-to-end on a self-host install. Tested scenarios, findings, gotchas, cheat sheets, and reusable tooling — written so the next person trying to ship a multi-agent platform on Multica doesn't have to learn it the hard way.

> **What this is not:** a fork or replacement of the official Multica docs. For installation/architecture canon, read the upstream [README](https://github.com/multica-ai/multica) and `CLI_AND_DAEMON.md`. This repo covers what those don't: opinionated runbooks, observed behavior under different specs, edge cases I hit, and the reusable scripts I wrote to debug/visualize chains.

---

## What's in here

| Section | Purpose |
|---|---|
| [`docs/01-quickstart.md`](docs/01-quickstart.md) | Get from zero → "first agent chain ran on my machine" in ~30 minutes |
| [`docs/02-cheatsheet.md`](docs/02-cheatsheet.md) | The `multica` CLI commands you'll use 90% of the time, organized by use case |
| [`docs/03-architecture-overview.md`](docs/03-architecture-overview.md) | Multica concepts in plain English (workspace / agent / skill / issue / runtime / autopilot), and what each agent tab actually controls |
| [`docs/04-state-machine.md`](docs/04-state-machine.md) | How an orchestrator agent decides what to do on every wake — DISPATCH / ADVANCE / REVISE / CLOSE / ESCALATE / FAN-OUT |
| [`docs/05-handoff-protocol.md`](docs/05-handoff-protocol.md) | The wake-on-assignment + JSON-tail-contract pattern that makes specialist agents composable |
| [`docs/06-tested-scenarios.md`](docs/06-tested-scenarios.md) | Every scenario I ran, what happened, and what I learned |
| [`docs/07-findings.md`](docs/07-findings.md) | Architectural confirmations, capability observations, platform gotchas, open questions |
| [`docs/08-upstream-issues.md`](docs/08-upstream-issues.md) | Bugs and small enhancements I'm proposing back to upstream Multica |
| [`scenarios/`](scenarios/) | Reproducible test recipes — copy/paste runbooks for each pattern |
| [`scripts/`](scripts/) | Tooling I wrote and used: timeline renderer, live event watcher |
| [`examples/`](examples/) | Real code an engineer agent produced, kept as artifacts of an actual run |

---

## Why this exists

I was trying to get a multi-agent platform on Multica running end-to-end and ran into a stack of small problems the docs don't cover:

- The git-config trap (agent commits ending up under the wrong identity if you have multiple GitHub accounts)
- `agent.custom_env` not settable via CLI on `agent create` (only via UI)
- `multica issue status` taking positional args while the rest of the CLI uses flags
- The retry-on-empty-description guard being load-bearing (without it, agents wake before reads land)
- Sonnet 4.6 being too capable to trip on simple gotcha-criteria, requiring genuine ambiguity to force a REVISE loop
- Skill scoping — workspace-level resources with per-agent assignments, not per-agent ownership

Every one of these took an hour or two to figure out. This repo is the writeup so the next person doesn't have to.

---

## Status

- ✅ Self-host install + daemon dispatch + isolated workspace per task — works
- ✅ End-to-end PR flow (DISPATCH → engineer → ADVANCE → QA Review → CLOSE) — verified, real GitHub artifacts
- ✅ JSON contract handoff parses reliably; reassignment-as-wake works as designed
- ✅ Cross-machine snapshot + clone is reliable (modulo `custom_env`)
- 🟡 REVISE loop — orchestrator code path correct; Sonnet 4.6 hard to trip into it on diff-verifiable specs
- 🟡 FAN-OUT multi-analyst — code path documented; testing in progress
- ⏳ Skill mutation experiment — pending
- ⏳ Edge cases (empty desc, malformed JSON, concurrent dispatch) — pending
- ⏳ Upstream PRs — three identified, drafting

See [`docs/06-tested-scenarios.md`](docs/06-tested-scenarios.md) for the full matrix.

---

## Quick start (90-second version)

If you just want a working chain on your machine:

```bash
# 1. Run Multica self-host (Docker)
git clone https://github.com/multica-ai/multica
cd multica && make selfhost

# 2. Install + auth the CLI (separate terminal)
brew install multica-ai/tap/multica
multica setup self-host

# 3. Start the daemon
multica daemon start

# 4. Create a simple agent
RUNTIME_ID=$(multica runtime list --output json | jq -r '.[]|select(.provider=="claude")|.id')
multica agent create \
  --name "echo-agent" \
  --description "Posts a comment with whatever the issue describes" \
  --runtime-id "$RUNTIME_ID" \
  --model "claude-sonnet-4-6" \
  --visibility workspace \
  --instructions "On wake: read the issue with 'multica issue get <id>'. Post a comment via 'multica issue comment add <id> --content \"received: <description>\"'. Mark the issue done with 'multica issue status <id> done'. Exit."

# 5. Fire your first issue
multica issue create \
  --title "Smoke test" \
  --description "Hello from the sandbox" \
  --assignee echo-agent
```

Open http://localhost:3000 in your browser and watch it run.

For anything more interesting (multi-agent chains, GitHub PRs, etc.), see [`docs/01-quickstart.md`](docs/01-quickstart.md).

---

## Tested chain — proof this isn't slideware

I ran the canonical multi-agent shape (orchestrator → engineer → qa-review) on this exact repo. Here's the timeline of one run:

```
00:00  PARENT created, assigned to orchestrator
00:01  orchestrator wakes (DISPATCH)
00:46  engineer sub-issue created, assigned to engineer
00:49  engineer wakes — clones repo, branches, writes code, opens PR
02:43  engineer hands back: "PR opened, status: completed"
02:54  orchestrator wakes on engineer sub-issue (ADVANCE)
03:48  orchestrator closes engineer sub-issue, creates qa-review sub-issue
03:53  qa-review wakes — reads PR diff against acceptance criteria
05:37  qa-review verdict: approved, FULL spec compliance
05:53  orchestrator wakes on qa-review sub-issue (CLOSE)
06:35  parent + qa-review both flipped to done
```

**6m 35s, all-real artifacts.** The code the engineer agent produced lives in [`examples/api-hello-route.ts`](examples/api-hello-route.ts) — actual output, not a mock.

---

## License

MIT (see `LICENSE`). Findings and scripts are free to use, copy, adapt.

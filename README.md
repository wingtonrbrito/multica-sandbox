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
| [`docs/08-upstream-issues.md`](docs/08-upstream-issues.md) | Bugs and small enhancements I'm proposing back to upstream Multica (with diff sketches) |
| [`UPSTREAM-CONTRIBUTIONS.md`](UPSTREAM-CONTRIBUTIONS.md) | **Live status table** of upstream PRs (filed / queued / not yet) + findings catalog. The quick-glance version of `docs/08`. |
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
- ✅ FAN-OUT multi-analyst (arch + security → synthesizer → CLOSE-MULTI) — verified, **the agents found and we fixed two real bugs in this very repo**
- ✅ JSON contract handoff parses reliably; reassignment-as-wake works as designed
- ✅ Cross-machine snapshot + clone is reliable (modulo `custom_env`)
- ✅ **Skill scoping empirically resolved** — workspace-level, fetched fresh on every wake, no per-agent cache (closes a long-open architectural question)
- ✅ **REVISE state machine validated** via manual `needs-revision` injection — orchestrator dispatched engineer revision 1 with correct naming + notes; engineer pushed a real revision commit; re-review dispatched. (Sonnet 4.6 too capable to trip organically across 3 real-spec attempts.)
- ⏳ Edge cases (empty desc, malformed JSON, concurrent dispatch) — pending
- ⏳ Upstream PRs — three identified, drafting

See [`docs/06-tested-scenarios.md`](docs/06-tested-scenarios.md) for the full matrix.

---

## Quick start (90-second version)

If you just want a working chain on your machine, **use our fork's `wingtonrbrito-customizations` branch**. It bundles all our open upstream PRs (`--to` flag for `issue status`, daemon backend connectivity, plus the Huly MCP fixes) so you don't have to wait for upstream merges.

```bash
# 1. Run Multica self-host (Docker) — our fork with all open PRs included
git clone https://github.com/wingtonrbrito/multica
cd multica
git checkout wingtonrbrito-customizations
make dev                                         # auto-creates env, installs deps, starts DB, migrates, launches app

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

> **Want stock upstream instead?** `git clone https://github.com/multica-ai/multica` — same setup, no fork patches. Use this if you want pure upstream behavior for comparison; use the fork above if you want the working version with our open PRs already merged in.

### Wiring Huly into the orchestrator (full GitHub ↔ Huly ↔ Multica round trip)

For the end-to-end loop where a Huly issue triggers a Multica chain, the chain creates a GitHub PR, and the orchestrator flips the Huly ticket back to `Todo` + reassigns to a Reviewer:

```bash
# 1. Clone our huly-mcp-server fork (includes assignee + add_comment + Node polyfill)
git clone https://github.com/wingtonrbrito/huly-mcp-server
cd huly-mcp-server
git checkout wingtonrbrito-customizations
npm install

# 2. Set Huly env vars
export HULY_URL=https://your-huly-host
export HULY_EMAIL=...
export HULY_PASSWORD=...
export HULY_WORKSPACE=...

# 3. Wire it into Claude Code MCP config (~/.claude/claude_desktop_config.json)
#    or your runtime's mcp_config — see CUSTOMIZATIONS.md on the fork for the exact shape.
node launch.mjs        # smoke-test: should connect and list workspaces
```

Then attach your Multica orchestrator to the `huly-scan` and `huly-writeback` skills (see the round-trip runbook for the complete flow).

For anything more interesting (multi-agent chains, GitHub PRs, full Huly round trip, edge cases), see [`docs/01-quickstart.md`](docs/01-quickstart.md) and [`docs/fork-strategy.md`](docs/fork-strategy.md).

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

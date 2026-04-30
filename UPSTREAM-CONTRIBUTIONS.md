# Upstream Contributions

Tracking table for issues found while running Multica end-to-end + the PRs we've opened against [`multica-ai/multica`](https://github.com/multica-ai/multica) and other relevant repos.

Updated whenever a PR moves through state.

---

## PR status table

| # | Title | Repo | PR # | Status | Why it matters |
|---|---|---|---|---|---|
| 1 | `fix(cli): add --to flag to issue status (preserve positional form)` | [`multica-ai/multica`](https://github.com/multica-ai/multica) | [#1805](https://github.com/multica-ai/multica/pull/1805) | 🟢 Open — under review | `multica issue status` was the only CLI verb taking a target status that's positional-only. Every other surface uses `--to`/`--status`. Fully backward-compatible. |
| 2 | `feat(cli): add --custom-env flag to agent create/update` | [`multica-ai/multica`](https://github.com/multica-ai/multica) | superseded | ⚪ Already shipped upstream (#1907 era) | Maintainers shipped this independently — went further with `--custom-env-stdin` and `--custom-env-file` for secret hygiene. Drop our queued patch. |
| 3 | `feat(daemon): surface backend connectivity in daemon status` | [`multica-ai/multica`](https://github.com/multica-ai/multica) | [#1910](https://github.com/multica-ai/multica/pull/1910) | 🟢 Open — under review | When Docker backend goes down, daemon stays "running" but can't poll. Silent failure mode. New `backend_connectivity` field on `HealthResponse`; surfaces as `Backend:` line in `daemon status`. 4 new test cases. |
| 4 | `feat: add launch.mjs polyfill for Node MCP runtime` | [`kwhittenberger/huly-mcp-server`](https://github.com/kwhittenberger/huly-mcp-server) | [#2](https://github.com/kwhittenberger/huly-mcp-server/pull/2) | 🟢 Open — under review | The Huly api-client expects browser globals (`window`, `document`, `indexedDB`). A 56-line launcher shim makes the mcp boot in Node MCP-server contexts. Helps anyone running it against Huly Cloud. |
| 5 | `feat: add add_comment + list_issue_relations tools` | [`kwhittenberger/huly-mcp-server`](https://github.com/kwhittenberger/huly-mcp-server) | [#3](https://github.com/kwhittenberger/huly-mcp-server/pull/3) | 🟢 Open — under review | Closes Huly comment-writeback (Multica orchestrator's `huly-writeback` skill needs `add_comment`) and `probe-repo-linkage`-style probe workflows (need `list_issue_relations`). Verified live against Huly Cloud. |
| 6 | `feat: add assignee param to update_issue (resolve by email via Channel)` | [`kwhittenberger/huly-mcp-server`](https://github.com/kwhittenberger/huly-mcp-server) | [#4](https://github.com/kwhittenberger/huly-mcp-server/pull/4) | 🟢 Open — under review | Caught during the 2026-04-30 round-trip e2e: status flip on CLOSE worked, but Reviewer reassignment silently no-op'd because `update_issue` lacked an assignee parameter. Resolves email → Employee via Huly's Channel records. The orchestrator's assignment-failure-policy correctly fell back to status-flip-only and recorded a notes entry, so the chain succeeded — but the human reviewer never saw the ticket land in their queue. This PR fixes that. |

**Status legend:**
- 🟢 Open / merged — actively in upstream review or already landed
- 🟡 Drafted / filing — patch ready, PR not yet opened
- 🔴 Not yet — needs work before filing
- ⚪ Won't fix — declined or superseded

---

## Findings catalog (informational, not necessarily PRs)

These are observations from running the platform end-to-end. Some become PRs, some are documentation gaps, some are intentional design choices worth knowing.

| # | Finding | Implication | PR? |
|---|---|---|---|
| F1 | Daemon strips `--mcp-config` from `agent.custom_args` (security feature) | Use `agent.mcp_config` field instead; CLI has no flag for it (see PR #2 above) | Indirectly via #2 |
| F2 | Engineer agents commit under wrong identity if repo-local git config is unset | Multi-account developers leak the wrong author into PRs. Fix: `git config user.email` per cloned repo, or patch `feature-implementation` skill | No (skill-content gap) |
| F3 | `agent skills set` is atomic full-replace (no `add`/`remove` verbs) | Scripting partial skill updates requires read-modify-write | Maybe (low priority) |
| F4 | Skills are workspace-scoped, fetched on every wake, no per-agent cache | Hot-patching across all attached agents is one CLI call. No skill-version concept; rollback requires external snapshot | Resolved (informational) |
| F5 | FAN-OUT chain found 2 real bugs in the showcase repo on its first run | Cross-lens synthesis adds value beyond individual analyst reports | Already-fixed in this repo |
| F6 | REVISE state machine is correct (validated via manual injection) — but Sonnet 4.6 too capable to trip organically on diff-verifiable specs | Cross-model review pattern (Codex for QA, Claude for engineer) is the right design | Validates upstream design |
| F7 | Read-after-write race + retry-on-empty guard is load-bearing | Without the 3-attempt retry, fresh sub-issues fail intermittently | Open question whether fixed in newer Multica versions |

---

## How to follow upstream

- **PR #1805's status** is the canonical signal for "are the maintainers receptive to small ergonomic fixes." If it lands cleanly, expect PR #2 and #3 to follow the same shape.
- All our upstream branches live on the fork [`wingtonrbrito/multica`](https://github.com/wingtonrbrito/multica). Branch names follow `<type>/<scope>-<short-summary>` (e.g., `fix/cli-issue-status-to-flag`).
- Long-lived customizations branch: [`wingtonrbrito/multica:wingtonrbrito-customizations`](https://github.com/wingtonrbrito/multica/tree/wingtonrbrito-customizations) — local patches that aren't (yet) upstream-bound.

## Want to consume our fork?

See [`docs/fork-strategy.md`](docs/fork-strategy.md) for the recipes (cherry-pick a specific commit, fork our fork, add as remote, etc.).

---

_Last updated: 2026-04-30 (5 PRs open, 1 superseded by upstream, 1 RFC filed as issue)_

## Open RFCs (upstream issues)

| # | Title | Repo | Issue # | Status | Why it matters |
|---|---|---|---|---|---|
| R1 | RFC: outbound webhooks on issue/run state transitions | [`multica-ai/multica`](https://github.com/multica-ai/multica) | [#1964](https://github.com/multica-ai/multica/issues/1964) | 🟢 Filed — awaiting maintainer feedback | Lets external systems (Huly, n8n, Slack) react to Multica state changes without polling AND without burning LLM tokens via orchestrator-driven writebacks. Reuses the existing internal `events.Bus`. |

## Adoption pass — 2026-04-30

Walked through David's updated DD-Demo (re-snapshot at `docs/multica/david-snapshot/2026-04-29/`) and adopted his three big design shifts onto self-host:

1. **Round-trip is a status-loop** (Backlog → Multica work → Todo + reassign to Reviewer). Not Huly-mediated PR creation as I had inferred from the Apr 29 meeting. Mirrored the `huly-scan` (8787 b → 13343 b) and `huly-writeback` (10866 b → 12942 b) skills.
2. **Synthesizer-without-duplicate-issue** solved via race-tight pre-check + cancel-newer + a new `Orchestrator Sweep` autopilot for recovery audits. Mirrored both onto self-host (orchestrator instructions 45215 b → 54604 b, sweep autopilot created without trigger).
3. **Predecessor-purge pattern** for autopilot tick-tracking issues. Wrote `ds-org-suite/scripts/multica-purge-huly-scans.py` and verified end-to-end (cleaned 213 stale `Huly Scan` tracking issues from the prior day's autopilot ticks).

Round-trip runbook at `docs/multica/04-roundtrip-test.md` — describes the full Backlog → Todo + reassignment loop using the mirrored skills against the `multica-e2e-sandbox` Huly workspace.

PR statuses unchanged since 4-29 except: PR #1805's frontend CI is currently failing on an unrelated `apps/web/login/page.test.tsx` timeout (likely flake — my change only touches `server/cmd/multica/cmd_issue.go`).

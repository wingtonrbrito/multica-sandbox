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

_Last updated: 2026-04-29 (4 PRs filed, 1 superseded by upstream)_

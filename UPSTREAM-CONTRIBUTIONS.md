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
| **F8** | `kwhittenberger/huly-mcp-server`'s `update_issue` tool doesn't accept `assignee` param | CLOSE-phase status flip lands; Reviewer reassignment silently no-op's. Caught in 2026-04-30 round-trip e2e. The orchestrator's assignment-failure-policy fallback (status-flip + notes) handles cleanly so the chain doesn't break — but the human reviewer never sees the ticket land in their queue. | ✓ Filed as PR #4 (above) |
| **F9** | Huly↔GH integration's reverse-sync overrides Huly assignee within seconds of CLOSE setting it correctly | **Distinct from F8** — F8 is tool-level (the tool can't set assignee); F9 is integration-level (the integration overrides assignee after we set it). Both real, neither substitutes the other. David shipped a Phase 4b orphan-assignee repair in the SWEEP procedure to compensate. | No PR — David's Phase 4b is the right shape; we don't run the Huly↔GH integration on self-host so the gap isn't active for us |
| **F10** | Huly↔GH integration's comment mirror is partial on long chains — initial dispatch lands on GH, chain-end narrative drops | David shipped a `gh-chain-end-comment` skill that compensates by posting an explicit chain-end on both sides (GH issue + Huly ticket). The post-filter on `huly-for-github` author is the right call against `gh search issues` false positives. | No PR — same scope-conditional reasoning as F9 |
| **F11** | `/api/autopilots` returns 500 on self-host (RESOLVED 2026-05-05) | Backend image went stale (built 4-21) while the database migrated forward to v067 — binary still SELECT'd dropped columns. The handler swallowed the underlying SQL error to a generic 500. Discovered while smoke-testing E9 against post-cascade self-host. | Resolved via `make selfhost-build`. Worth a tiny upstream PR adding `log.Err(err).Msg(...)` before the generic `writeError` in the autopilot handler so the underlying SQL error shows in stderr. Not yet filed. |

---

## Consuming the working version today

Until upstream merges these PRs, both forks expose a `wingtonrbrito-customizations` branch that bundles our open patches with the latest upstream so you get a working build in one checkout — on any device, any time:

**Multica core:**
```bash
git clone https://github.com/wingtonrbrito/multica
cd multica
git checkout wingtonrbrito-customizations
make dev
```
Includes: PR #1805 (`--to` flag) + PR #1910 (daemon backend connectivity). See [`CUSTOMIZATIONS.md`](https://github.com/wingtonrbrito/multica/blob/wingtonrbrito-customizations/CUSTOMIZATIONS.md) on the fork.

**Huly MCP server:**
```bash
git clone https://github.com/wingtonrbrito/huly-mcp-server
cd huly-mcp-server
git checkout wingtonrbrito-customizations
npm install
node launch.mjs
```
Includes: PR #2 (Node-runtime polyfill) + PR #3 (`add_comment`/`list_issue_relations`) + PR #4 (assignee param). See [`CUSTOMIZATIONS.md`](https://github.com/wingtonrbrito/huly-mcp-server/blob/wingtonrbrito-customizations/CUSTOMIZATIONS.md) on the fork.

Both branches are rebuilt on top of upstream `main`/`master` whenever upstream advances; force-pushed with `--force-with-lease`. When a PR lands upstream, the corresponding feature branch drops out of the merge graph on the next sync.

## How to follow upstream

- **PR #1805's status** is the canonical signal for "are the maintainers receptive to small ergonomic fixes." If it lands cleanly, expect PR #2 and #3 to follow the same shape.
- All our upstream branches live on the forks. Branch names follow `<type>/<scope>-<short-summary>` (e.g., `fix/cli-issue-status-to-flag`).

## Want to consume our fork?

See [`docs/fork-strategy.md`](docs/fork-strategy.md) for the full recipes (cherry-pick a specific commit, fork our fork, add as remote, multi-project / multi-device reuse).

---

_Last updated: 2026-05-08 (5 PRs open, 1 superseded by upstream, 1 RFC filed as issue; F8-F11 added; full Huly→Multica→GitHub round-trip verified live today with HULY-9 → DSO-5 → PR #5; both forks expose `wingtonrbrito-customizations` branches bundling all open patches.)_

## Open RFCs (upstream issues)

| # | Title | Repo | Issue # | Status | Why it matters |
|---|---|---|---|---|---|
| R1 | RFC: outbound webhooks on issue/run state transitions | [`multica-ai/multica`](https://github.com/multica-ai/multica) | [#1964](https://github.com/multica-ai/multica/issues/1964) | 🟢 **Maintainer reviewed 2026-05-06** — direction approved, asks for spec hardening + draft PR | Lets external systems (Huly, n8n, Slack) react to Multica state changes without polling AND without burning LLM tokens via orchestrator-driven writebacks. Reuses the existing internal `events.Bus`. **Maintainer (`Bohan-J`) called out 4 blocking concerns to fold into spec before draft-PR:** (1) align event-type names with the bus's actual published taxonomy (`task:*`, `issue:updated`, etc.) instead of inventing new ones; (2) add a persisted `webhook_deliveries` table for retries that survive restarts; (3) address SSRF (block private/loopback ranges + cloud metadata IPs at DNS-resolution time); (4) mint `Event.ID` at `Publish` time as UUIDv7. Plus 5 sharpening points (configurable pause threshold, deliveries-CLI body inclusion, retry timing) and 7 smaller items. Verdict: *"Convert to a draft PR — but with #1, #2, #3, #4 folded into the spec first."* |

## Adoption pass — 2026-04-30

Walked through David's updated DD-Demo (re-snapshot at `docs/multica/david-snapshot/2026-04-29/`) and adopted his three big design shifts onto self-host:

1. **Round-trip is a status-loop** (Backlog → Multica work → Todo + reassign to Reviewer). Not Huly-mediated PR creation as I had inferred from the Apr 29 meeting. Mirrored the `huly-scan` (8787 b → 13343 b) and `huly-writeback` (10866 b → 12942 b) skills.
2. **Synthesizer-without-duplicate-issue** solved via race-tight pre-check + cancel-newer + a new `Orchestrator Sweep` autopilot for recovery audits. Mirrored both onto self-host (orchestrator instructions 45215 b → 54604 b, sweep autopilot created without trigger).
3. **Predecessor-purge pattern** for autopilot tick-tracking issues. Wrote `ds-org-suite/scripts/multica-purge-huly-scans.py` and verified end-to-end (cleaned 213 stale `Huly Scan` tracking issues from the prior day's autopilot ticks).

Round-trip runbook at `docs/multica/04-roundtrip-test.md` — describes the full Backlog → Todo + reassignment loop using the mirrored skills against the `multica-e2e-sandbox` Huly workspace.

PR statuses unchanged since 4-29 except: PR #1805's frontend CI is currently failing on an unrelated `apps/web/login/page.test.tsx` timeout (likely flake — my change only touches `server/cmd/multica/cmd_issue.go`).

## Adoption pass — 2026-05-01

Re-snapshotted David's DD-Demo at 2026-05-01 and identified three new shifts since 4-29:

1. **Phase 4b orphan-assignee repair** in orchestrator SWEEP procedure — fixes F9 (Huly↔GH integration reverse-sync overrides assignee). Anti-flap cooldown built in.
2. **NEW skill `gh-chain-end-comment`** wired into orchestrator's CLOSE + CLOSE-multi-analyst paths — fixes F10 (partial-mirror failure on long chains).
3. **Removed `data-analyst` agent + `data-layer-analysis` skill** (Snowflake cortex couldn't be targeted) with cascading triage / synthesizer / FAN-OUT validation updates.

**Adoption decisions on self-host:**
- ✓ Mirrored: data-analyst retirement, 4 clean-cascade skills (`analyst-handoff`, `arch-review`, `security-review`, `report-synthesis`), `probe-repo-linkage` cascade portion (Probe 4 surgically excised), synthesizer + orchestrator data-analyst cascade.
- ✗ Skipped: Phase 4b orphan-assignee repair, `gh-chain-end-comment` skill, `probe-repo-linkage` Probe 4 — all integration-specific. Self-host doesn't run the Huly↔GH integration so the override and partial-mirror failures don't manifest.

Apply tooling at `ds-suite/ds-org-suite/adoption-2026-05-01/apply.sh` with byte-count verification.

## Reactive bridges — 2026-05-08

Wired two new autopilots on self-host to close the inbound-from-GitHub and PR-comment loops. Both are orchestrator-assigned with the procedure embedded in the autopilot description (no orchestrator instruction edit needed):

| Autopilot | Purpose | How it works |
|---|---|---|
| **GitHub Issue Scan** | New GH issue → mirror to Huly → existing Huly Scan ingests into Multica | `gh issue list` filtered to label `multica-sandbox-task` or title prefix `[multica-bot]`. Idempotency-checks against Huly via `mcp__huly__list_issues` substring match. Creates Huly issues with `Reviewer:` + `GitHub: <url>` shape. Caps at 5 per tick. |
| **PR Comment Watch** | New external comment on a chain-authored PR → dispatch revision engineer sub-issue | Enumerates Multica parents with PR URLs in description; runs `gh pr view` per PR; filters comments to last-60-min external authors (drops own engineer/qa/integration-mirror). Dispatches `[engineer] revision <N>` sub-issues with comment body verbatim + push-to-existing-branch instructions. Caps at 3 per tick. |

Both intentionally chain into existing flows: Issue Scan creates Huly issues that Huly Scan picks up; Comment Watch dispatches sub-issues that the existing engineer handoff handles. No race-tight guards yet (both have manual-trigger only, no cron) — easy to attach a cron via the UI when ready for unattended runs.

## Live e2e validation — 2026-05-08

Post-Docker-rebuild end-to-end run confirms the platform reproduces David's 5-04 design (with our skip decisions) and the round-trip works against real artifacts.

```
HULY-9 (Backlog, Reviewer: codingin30@gmail.com) — real Huly issue
  ↓ Huly Scan autopilot tick (DSO-4)
DSO-5 (Multica parent ingested with Huly: HULY-9 + Reviewer: shape)
  ↓ orchestrator DISPATCH
DSO-6 (engineer) → opened https://github.com/wingtonrbrito/multica-sandbox/pull/5 — real GitHub PR
  ↓ orchestrator ADVANCE
DSO-7 (qa-review) → APPROVED
  ↓ orchestrator CLOSE → huly-writeback flips HULY-9 to Todo + reassigns to Reviewer
DSO-5 done
```

Earlier the same day, a parallel non-Huly chain (DSO-1→DSO-3) opened [PR #4](https://github.com/wingtonrbrito/multica-sandbox/pull/4) and ran qa-review on it, also reaching CLOSE cleanly. Two real chains in one demo session.

**What this proves end-to-end:**
- Bootstrapping the platform from a clean Docker nuke takes ~60 minutes (`make selfhost-build` + clone-from-snapshot + apply our cascade)
- Specialists are Huly-unaware; only the orchestrator has `mcp_config` for Huly
- The handoff protocol (status-flip + reassign + JSON contract) wakes the next agent reliably across 3 specialist hops
- Real GitHub PR creation, real QA approval, real Huly status writeback — all in ~10 minutes per chain

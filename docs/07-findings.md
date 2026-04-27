# 07 — Findings

What I learned setting up Multica from scratch and running multi-agent chains end-to-end. Organized by category. Each finding either confirms something about the platform's design or surfaces a gotcha you should know before building on it.

## Architectural confirmations

### 1. Hub-and-spoke runs cleanly on a fresh runtime
The full state machine (DISPATCH → engineer → ADVANCE → qa-review → CLOSE) executed without a single intervention on a freshly-installed self-host. Confirms the design is portable across machines and model fleets — I ran it with Claude Sonnet 4.6 across all roles instead of David's Opus + Codex split.

### 2. Reassignment-as-wake-signal works as intended
Every handoff used the documented pattern: status flip to `todo` + reassignment to next agent. Comments alone didn't wake. **Treat reassignment as the only wake event** when designing new specialists.

### 3. JSON contract handoff parses reliably
Engineer's `pr_url` JSON block was extracted by the orchestrator without issue. Same for QA Review's `review_decision`. The trailing-fence-block convention is robust to narrative content above it. No `synthesize-extract` failures observed.

### 4. Read-after-write race + retry-on-empty guard works
Agents woke and read fresh sub-issue descriptions without empty-description blocks. The 3-attempt retry guard is not just defensive — without it, the same race-condition failure would recur. Worth keeping in any new specialist prompt.

### 5. Conditional Huly writeback (skip when HULY_ID unset)
We omitted `Huly:` from the parent description. Orchestrator silently skipped the writeback path. Confirms: writeback is conditional, not unconditional. No errors emitted from missing Huly MCP.

## Engineer / model capability observations

### Sonnet 4.6 is too capable on diff-verifiable specs
Two runs with progressively stricter acceptance criteria — basic spec, then strict RFC 7231 with HEAD export + Allow headers + Vary headers — both approved on first try. To force a REVISE loop, the spec must include at least one of:
- Genuine ambiguity (two reasonable interpretations, only one matches)
- Multi-file scope where engineer must touch >1 file correctly
- Behavior not visible in the diff (e.g., test coverage thresholds, performance budgets)
- A specification of *non-existent* APIs the engineer would have to invent

This is a finding, not a complaint — the platform's success rate on simple tasks is high.

### QA Review correctly distinguishes "unverifiable" from "missing"
On the first run, QA flagged `lint passes on the new file` as unverifiable because the sandbox repo has no lint configuration. It did NOT mark the criterion as failed. **QA's `code-review` skill correctly distinguishes "not satisfied" vs "not measurable from this diff."** A platform-level signal of trustworthiness.

### Cross-model review is intentional
David's `QA Review` agent runs on Codex (GPT-5.4) deliberately so the reviewer is a different model than the one that wrote the code. We had to map QA to Claude since no local Codex runtime — this is lower fidelity but still validates the protocol. Preserve the cross-model pattern when you reproduce in production.

## Multica platform gotchas

### Gotcha 1 — `agent.custom_env` cannot be set via CLI
`multica agent create` and `multica agent update` have no `--custom-env` flag. Only the UI's Environment tab (or direct API call) can set env vars. Means cloning agents from a JSON snapshot can't fully reproduce the env config without manual UI work. **Upstream PR pending** — see [`08-upstream-issues.md`](08-upstream-issues.md#gap-1).

### Gotcha 2 — `multica issue status` is positional-only
`multica issue status <id> <new-status>` — no `--to` or `--status` flag. Inconsistent with the rest of the CLI. **Upstream PR pending** — see [`08-upstream-issues.md`](08-upstream-issues.md#gap-2).

### Gotcha 3 — Daemon stays "running" when backend is down
When Docker backend goes down, daemon process stays alive (no crash) but can't poll for assignments. `multica daemon status` doesn't surface the broken connectivity. Silent failure mode that bit me directly during testing. **Upstream PR pending** — see [`08-upstream-issues.md`](08-upstream-issues.md#gap-3).

### Gotcha 4 — Default git config dominates if repo-local is unset
Engineer's first run committed under my global git identity (`neybapps`) because the cloned repo had no local `user.name` / `user.email` set. **Any agent platform that invokes `git commit` should set repo-local identity at clone-time, not rely on global config.** Without this, multi-account developers leak the wrong identity into agent-authored PRs.

### Gotcha 5 — SSH alias-based push works through agents transparently
After switching the remote URL to use an SSH alias (`git@github-personal:wingtonrbrito/repo.git`), the engineer agent's `git push` automatically used the right SSH key via `~/.ssh/config`. **No daemon-level configuration needed; the agent inherits HOME and SSH config from the user.** Confirms per-repo key isolation works out of the box.

### Gotcha 6 — `agent skills set` is atomic full-replace
Not `add` / `remove` — the `set` subcommand replaces the FULL list of attached skills. Easy to forget when scripting partial updates. Combined with workspace-level scoping (skills aren't per-agent), this confirms the "library + assignments" mental model is the right one to internalize.

## Identity / authentication learnings

### gh CLI multi-account
`gh auth login` adds an account but doesn't switch the active one automatically; **`gh auth switch -u <login>`** is the required second command. Easy to forget.

### Git's commit author vs pusher are independent
- **Pusher** (write authorization): determined by SSH key or HTTPS token at push time
- **Commit author**: determined by git config at commit time

A correctly-authorized push can land wrong-author commits on a correctly-owned repo. **Both must be aligned** for clean attribution. Setting repo-local git config at clone time is the simplest fix.

### Why repo-local git config beats global
Setting `--global` would affect every other repo on the user's machine — invasive. Setting `--local` in the agent's working repo is the right scope.

## Skills scoping (David's research question, partially answered)

From surface inspection of David's workspace + behavior on our clone:

- All skills are workspace-level (`workspace_id` set, `agent_id: null`)
- `multica skill create` has no agent-scoping flag
- `multica agent skills` only has `list` and `set` (atomic) — no `add`/`remove`

**Implication:** there is no per-agent private skill library. Adding a skill to an agent is an *assignment*, not a *scoping* operation. Modifying the skill changes it for every agent that references it.

What's still empirically open:
- Mid-flight task behavior — does an agent re-read skill content on every wake, or cache at dispatch time?
- Skill version semantics — there's no `skill version` concept; modifications are in-place

Will close out by running [Scenario 05 — Skill mutation](06-tested-scenarios.md#scenario-05--skill-mutation).

## The agents found real bugs in this repo

The most concrete signal of value: when I ran a FAN-OUT multi-analyst scenario against `multica-sandbox` itself (arch + security panel), both analysts found **real bugs** in the repo — not theatrical demo-grade issues.

**security-analyst (LOW):** `scripts/multica-watch.sh:28-30` used `STATE_DIR="${TMPDIR:-/tmp}/multica-watch-$$"` followed by `mkdir -p` (no ownership check) and `trap 'rm -rf "$STATE_DIR"' EXIT`. On shared-tmp Linux hosts, an attacker who can race the PID can pre-create the directory containing symlinks; the EXIT trap may follow them for arbitrary deletion (CWE-377 / CWE-379 / CWE-59). **One-line fix:** swap to `mktemp -d -t multica-watch.XXXXXX`. Done.

**arch-analyst (integrity):** `docs/02-cheatsheet.md:163` referenced `scripts/multica-clone-from-snapshot.py`, which doesn't exist in the tree. Forward reference / lost in commit reshuffle. **Fix:** rewrite the cheatsheet line to point at the trace-issue script as a template instead. Done.

**synthesizer cross-cutting:** the two operational scripts (~200 LOC) concentrate almost ALL material findings from both lenses despite being a small minority of LOC. Recommendation: a single small "scripts-hardening" PR closes most residual risk. This is the cross-lens kind of insight you only get from synthesis on top of multiple analyses — not from any single analyst report.

The chain found, classified (with full CWE references), and proposed one-line fixes for two real issues in 13m 32s. This is the value proposition of the platform in concrete form.

## Open questions worth bringing to the Multica team

1. Is there a recommended pattern for setting `custom_env` programmatically? Or is UI-only intentional?
2. Has the read-after-write race been fixed in newer Multica versions, or is the retry-on-empty guard still load-bearing?
3. What's the agent-timeout boundary behavior (default 2h)? Does the daemon kill the subprocess at exactly 2h, or is there grace?
4. Is there interest in workspace-level shared MCP config (one file, multiple agents reference) as a first-class feature?
5. Cross-workspace skill sharing — feature roadmap item, or out of scope?

## What I'd build next on this platform

- An explicit "approval gate" autopilot pattern (orchestrator pauses before merging PR, waits for human +1)
- A "scout" specialist that runs before DISPATCH to gather context (read repo's README, recent commits, etc.)
- A `multica-pdb` tool — break into a chain mid-flight, replay last decision, modify state
- Per-chain tracing as a first-class concept (replace my home-grown `multica-trace-issue.py`)

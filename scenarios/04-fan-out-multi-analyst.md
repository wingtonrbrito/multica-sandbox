# Scenario 04 — FAN-OUT multi-analyst panel

**Status:** ✅ Passed (2026-04-27). Total chain time: 13m 32s. Found 2 real bugs in this repo.

The orchestrator's most interesting state-machine path: parallel dispatch to 2+ specialists, wait for all to complete, then SYNTHESIZE-MULTI dispatches a synthesizer agent that combines findings into a unified report, then CLOSE-MULTI closes everything.

## The trigger

The orchestrator's triage rules have a special case that fires BEFORE single-specialist matching: if the parent description contains a line of the form `Analyst panel: <list>` (case-insensitive prefix), where `<list>` is two or more of `arch`, `security`, `data` — orchestrator goes to FAN-OUT DISPATCH instead of normal triage.

## Setup

You need (in addition to the basic 3 agents from Scenario 01):
- `arch-analyst` — read-only structural code review specialist
- `security-analyst` — read-only OWASP-top-10 security review
- `data-analyst` — read-only structured-data layer review (optional for this run)
- `synthesizer` — combines analyst findings

Each analyst has the `analyst-handoff` skill attached. Synthesizer has `analyst-handoff` + `report-synthesis`.

## The issue

```bash
# A repo to actually review (for example, this sandbox or any other small repo)
TARGET_REPO=/absolute/path/to/some/repo

multica issue create \
  --title "Multi-perspective review of $(basename $TARGET_REPO)" \
  --assignee orchestrator \
  --priority medium \
  --description "Analyst panel: arch, security

Review the repository for architecture and security concerns.
Target repo: $TARGET_REPO

Architecture analyst: structural review only. Note layering, coupling, technical debt.
Security analyst: OWASP top-10 lens. Note injection, auth, access-control, secrets, misconfig.

Each analyst must focus only on their lens — do NOT cross into the other's territory. The synthesizer will roll up.

Out of scope: code changes, test additions, performance benchmarks."
```

## Expected event sequence

```
parent created → orchestrator
orchestrator wakes (FAN-OUT DISPATCH triage)
  ├── creates [arch-analyst] sub-issue
  ├── creates [security-analyst] sub-issue
  └── posts "FAN-OUT dispatch — 2 analysts created" comment on parent

(parallel)
  arch-analyst wakes, reads code, posts findings + JSON, reassigns to orchestrator
  security-analyst wakes, reads code, posts findings + JSON, reassigns to orchestrator

(orchestrator wakes on each handoff individually — FAN-OUT-WAIT logic)
  arch handoff arrives first → orchestrator: "1 of 2 analysts complete"
  security handoff arrives → orchestrator: "all analysts complete, dispatching synthesizer"

orchestrator wakes (SYNTHESIZE-MULTI)
  └── creates [synthesizer] sub-issue with "Contributing sub-issues:" block

synthesizer wakes
  ├── reads each analyst sibling's findings
  ├── produces unified report (executive summary + cross-cutting themes + recommendations)
  └── posts findings + JSON, reassigns to orchestrator

orchestrator wakes (CLOSE-MULTI)
  ├── posts "Chain complete" on parent with synthesizer report URL
  └── flips parent + synthesizer to done
```

## What this proves (when it runs)

- FAN-OUT DISPATCH triage rule triggers correctly on `Analyst panel:` prefix
- Parallel dispatch works (2+ specialists can be in-flight simultaneously)
- FAN-OUT-WAIT correctly waits for all analysts (doesn't dispatch synthesizer prematurely)
- Synthesizer can read sibling sub-issue findings (cross-issue read, not just its own)
- CLOSE-MULTI handles the multi-issue closure correctly

## Common failure modes (anticipated)

| Symptom | Likely cause |
|---|---|
| One analyst completes, orchestrator dispatches synthesizer prematurely | Bug in FAN-OUT-WAIT logic or wrong assignment-routing |
| Synthesizer has empty `Contributing sub-issues:` block | `create-sub-issue-safely` skill's race-prevention failed |
| Synthesizer concatenates analyst findings instead of synthesizing | Synthesizer instructions need work — should explicitly forbid this |

Will document actual results here after running.

## Skipping data-analyst

I'm initially testing with just 2 analysts (arch + security) instead of 3 because:
- Data-analyst typically needs Snowflake/Cortex MCP wired up, which I don't have locally
- The pattern works with N≥2; 2 is sufficient to validate FAN-OUT-WAIT logic
- Adding the 3rd is incremental once the 2-analyst case works

## What this validates that Scenario 01/02 doesn't

- **Parallelism** — multiple specialists wake on overlapping intervals
- **Cross-issue reads** — synthesizer reads sibling sub-issues (not just its own)
- **Wait-for-quorum logic** — orchestrator only proceeds once N analysts complete
- **Synthesis-as-rewriting** — synthesizer must re-express findings, not just concatenate

---

## Actual results (2026-04-27)

### Timing
| Phase | Duration | Notes |
|---|---|---|
| Parent → orchestrator wake | <1s | Daemon polled within 5s |
| Orchestrator DISPATCH | 1m 17s | Triaged the `Analyst panel:` line, created 2 sub-issues, posted dispatch comment, exited |
| Both analysts running in parallel | 2m 51s and 3m 49s | security-analyst was 58s faster |
| Orchestrator FAN-OUT-WAIT (security handoff) | 1m 6s | Posted "1 of 2 analysts complete" while still waiting |
| Orchestrator SYNTHESIZE-MULTI (arch handoff arrived) | 23s | Detected quorum, created synthesizer sub-issue |
| Synthesizer rollup | 3m 31s | Read both sibling sub-issues, produced unified report |
| Orchestrator CLOSE-MULTI | 1m 33s | Closed parent + synthesizer |
| **Total** | **13m 32s** | |

### What the chain produced

Four sub-issues, all with substantive comments:
- arch-analyst — structural review (organization, coupling, tech debt)
- security-analyst — OWASP review (no production attack surface but two contained findings)
- synthesizer — unified Platform Analysis Report with executive summary, risk dashboard, cross-cutting themes, prioritized recommendations
- orchestrator's narrative on the parent: dispatch → "1 of 2 complete" → "all complete" → "chain complete"

### Real bugs the agents found

**security-analyst (LOW-severity):** `scripts/multica-watch.sh:28-30` used `STATE_DIR="${TMPDIR:-/tmp}/multica-watch-$$"` followed by `mkdir -p` (no ownership check) and `trap 'rm -rf "$STATE_DIR"' EXIT`. On shared-tmp Linux hosts a same-host attacker who can race the PID can pre-create the dir with symlinks; the EXIT trap's `rm -rf` may follow them for arbitrary deletion (CWE-377 / CWE-379 / CWE-59). Fixed in the same session (`mktemp -d` swap).

**arch-analyst (integrity bug):** `docs/02-cheatsheet.md:163` referenced `scripts/multica-clone-from-snapshot.py`, which doesn't exist in the tree. Phantom file. Either lost in a commit reshuffle or a forward reference not labelled as such. Fixed in the same session (rewrote the line to point at the trace-issue script as a template).

**synthesizer cross-cutting observation:** the two operational scripts (~200 LOC) concentrate almost all material findings from both lenses. The synthesizer's recommendation: a single small "scripts-hardening" PR closes most of the residual risk. This is exactly the kind of cross-lens insight you can't get from individual analyst reports — it falls out of synthesis.

### What this proves

- FAN-OUT DISPATCH triage rule fires correctly on `Analyst panel: <list>` line
- Parallel specialist dispatch works (2 simultaneous Claude Code subprocesses on the same runtime)
- FAN-OUT-WAIT correctly defers SYNTHESIZE-MULTI until ALL analysts return
- Cross-issue reads work — synthesizer accessed both sibling sub-issues' comment streams
- Synthesizer follows the "do not concatenate, re-express" rule — the report has new structure (Risk Dashboard, Cross-Cutting Themes) that neither analyst produced
- **The chain produces real value** — finding actual bugs in real code, not just executing protocol
- Multi-agent review at this quality level is a 13-minute workflow with one CLI invocation

### What surprised me

- security-analyst caught the `mktemp` issue with full CWE references and a one-line fix proposal — not just "this looks unsafe"
- arch-analyst counted ~25 inter-file links and traced for circularity (no scripted analysis, just careful reading) — this kind of due diligence in 3m 49s is striking
- synthesizer's "Cross-Cutting Themes" section identified that scripts/ is the highest-leverage attack surface despite being a minority of LOC — a cross-lens insight, not in either input
- The 5s polling interval means waking-after-handoff has up to ~10s of dead time per transition. For a 4-issue chain that's ~40s of dead air; mostly invisible because comparable to LLM inference time anyway

### How to reproduce

The exact issue body that fired this chain is at the top of this scenario file. Substitute your own `Target repo:` path. Watch with `scripts/multica-watch.sh` in a side terminal. Render the timeline after with `scripts/multica-trace-issue.py <parent-id>`.

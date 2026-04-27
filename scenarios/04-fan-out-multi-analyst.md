# Scenario 04 — FAN-OUT multi-analyst panel (planned)

**Status:** planned, not yet run.

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

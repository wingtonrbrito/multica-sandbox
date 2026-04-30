# Pattern — Approval-gate autopilot

When you want a human to gate-keep a Multica chain at a specific transition, before specialist work continues. Useful for:

- Production-bound code changes where a senior reviews the dispatch *before* the engineer starts coding
- Compliance flows (SOX, HIPAA, FERPA) where a chain pause + human sign-off is mandatory
- High-blast-radius changes (DB migrations, auth system mods) where you want explicit human consent before paying the LLM tokens for engineering

Builds on the same hub-and-spoke model. Adds one new specialist (`approval-gate`) and one new autopilot (`Approval Audit`).

## Topology

```
HULY-X (Backlog, has "REQUIRES_APPROVAL" tag)
    │ huly-scan ingests
    ▼
AIP-N (orchestrator)
    │ DISPATCH → approval-gate (instead of engineer/analyst)
    ▼
AIP-N1 [approval-gate] Awaiting human approval — <task summary>
    Status: todo, assignee: approval-gate (BUT: no agent runtime — see below)
    │ Human flips status to one of: approved | rejected
    ▼ on `approved`
    Approval Audit autopilot detects the flip → wakes orchestrator
    │ orchestrator's HANDOFF logic sees approval-gate child terminal w/ {status: approved}
    ▼
    DISPATCH → engineer (or analyst panel, etc. — original triage decision)
    ▼ chain proceeds normally to PR + QA + CLOSE
```

The `approval-gate` agent is a **stub agent with no runtime** — its only purpose is to be the assignee on the gating sub-issue so the issue can sit in `todo` waiting for human action. The "wake the orchestrator on approval" part is done by the **Approval Audit** autopilot, not by an automatic wake on assignment (that would require an LLM run we don't want).

## Why not just use `in_review` status?

`in_review` is the existing terminal-but-waiting-on-human signal. Two reasons it's not the right fit here:

1. `in_review` is a *post-work* state — work has been attempted, something escalated. Approval-gate is *pre-work* — nothing has been attempted yet, the human is gating the *initiation*.
2. The orchestrator's reactive HANDOFF logic treats `in_review` children as "blocked, escalate to parent." We want the opposite — humans flipping the gate child should *unblock* and resume dispatch, not escalate.

A new pre-work status (`awaiting_approval`) would also work, but adds a status to the lowercase status set, which has cross-system blast radius. The stub-agent pattern keeps the change isolated.

## Components

### 1. `approval-gate` agent

```
Name: approval-gate
Runtime: noop (or `claude` with --allowedTools "" so the agent can never actually do work)
Skills: (none — it never runs)
Description: Stub assignee for human approval gates. Never executes code.
             The Approval Audit autopilot is what wakes the orchestrator
             when a human flips this agent's child issue to `approved`.
```

A noop runtime is preferable; if Multica doesn't ship one, use `claude` with empty `--allowedTools` and a refusal-only system prompt: `"You never act. If invoked, exit immediately with status: blocked, summary: 'approval-gate is a stub — must not be invoked by daemon'."`. The autopilot pattern below means the daemon should never wake this agent, but the refusal prompt is a defensive belt-and-suspenders.

### 2. New triage rule in orchestrator instructions

In the DISPATCH triage section, add:

> If the parent issue's Huly description (or Multica description) contains the literal token `REQUIRES_APPROVAL` on its own line, dispatch to `approval-gate` BEFORE the role triage. The approval-gate sub-issue's title MUST be `[approval-gate] Awaiting human approval — <task summary>` and its description MUST include the original task ask plus a note: `Human reviewer: flip this issue's status to "done" to approve, or "cancelled" to reject. Do NOT post a comment as approval — the Approval Audit autopilot only watches status transitions.`

The `done`/`cancelled` choice is deliberate — they're already in the Multica status set, so we don't add a new one.

### 3. `Approval Audit` autopilot

Same shape as `Orchestrator Sweep`, but with a tighter focus:

```
Title: Approval Audit
Schedule: every 5 min (cron: */5 * * * *)
Mode: create_issue
Description:
  Scheduled APPROVAL_AUDIT tick. Run the procedure:
  1. List all Multica issues with title prefix "[approval-gate] " and status in (done, cancelled).
  2. For each: load the parent issue. If parent status is in_progress AND no engineer/analyst sub-issue
     exists yet, the orchestrator missed the wake — replay HANDOFF on the approval-gate child
     to resume dispatch.
  3. Phase 5: flip THIS tick-tracking issue to done; run predecessor-purge.
  4. Emit tick-summary JSON. Do NOT run reactive DISPATCH on this wake.
```

The audit autopilot is recovery, not the primary mechanism. The PRIMARY wake comes from the human's status-flip on the gate child — that flip wakes the orchestrator (assignment is reset to orchestrator on flip, see step 4 below).

### 4. Orchestrator HANDOFF rule for approval-gate children

In the orchestrator's HANDOFF logic, add:

> If the handing-back child's title starts with `[approval-gate]`:
> - On `done` → resume the original DISPATCH triage. Use the Multica issue tree's original ask (not the approval-gate restated ask) to triage.
> - On `cancelled` → CLOSE the parent with `chain_blocked_by_human_rejection` and a Huly comment explaining the rejection.

## Worked example

Huly issue:

```
Title: multica-sandbox: refactor auth middleware to use new JWT lib
Status: Backlog
Description:
  Reviewer: codingin30@gmail.com
  REQUIRES_APPROVAL

  Refactor server/auth/middleware.go to use github.com/lestrrat-go/jwx/v2 instead
  of the deprecated dgrijalva/jwt-go. Preserve existing token claim shape.
```

Trace:

1. `Huly Scan` autopilot ingests → creates `AIP-300` (orchestrator, status=todo).
2. Orchestrator wakes on AIP-300. Sees `REQUIRES_APPROVAL` token in description. Dispatches to `approval-gate` with sub-issue `AIP-301` titled `[approval-gate] Awaiting human approval — refactor auth middleware`.
3. AIP-301 sits in `todo` indefinitely. Daemon does NOT wake the approval-gate agent (noop runtime / refusal prompt).
4. Reviewer (codingin30@gmail.com) reviews the ask in Huly, opens Multica web UI, flips AIP-301 to `done`. The flip reassigns AIP-301 to the orchestrator (Multica's standard "child handoff" mechanic), which fires a wake.
5. Orchestrator wakes on AIP-301. HANDOFF logic sees the `[approval-gate]` prefix + `done` status → resumes dispatch. Triages the ORIGINAL parent ask (refactor auth) → engineer.
6. Chain proceeds: `[engineer] Refactor auth middleware ...`, then `[qa-review]`, then CLOSE → flip HULY-X to Todo + reassign to codingin30.

Rejection variant: at step 4 the reviewer flips AIP-301 to `cancelled` instead of `done`. Orchestrator sees the cancelled handoff, CLOSEs the parent, posts a Huly comment via huly-writeback's `ESCALATE` template with the rejection reason from a designated comment line on AIP-301, and re-flips the upstream Huly ticket back to `Backlog` (single exception to the never-flip-to-Backlog rule, called out explicitly in the orchestrator instructions).

## What this DOESN'T do

- **Per-step approval (each engineer commit gated).** That's a different pattern (post-PR-comment-approval, see the `pr-comment-loop` pattern). Approval-gate is *initial-dispatch*-only.
- **Multi-reviewer approval.** One reviewer, one decision. Multi-reviewer would require an extra synthesizer-style aggregation hop on the gate side.
- **Auto-expire on no-decision.** The gate child sits in `todo` forever if the human never acts. Add a separate "stale approval audit" autopilot that flips long-pending gate children to `cancelled` if the team wants a TTL.

## Status

Pattern designed. Not yet implemented on self-host. Dependencies:

- Multica needs a no-op runtime OR confidence the daemon will never wake `--allowedTools ""` agents on assignment.
- Orchestrator instructions need the new triage + HANDOFF rules added (small extension, ~30 lines).
- One new autopilot + one new agent.

Estimated effort: ~2 hours after the round-trip e2e test ships.

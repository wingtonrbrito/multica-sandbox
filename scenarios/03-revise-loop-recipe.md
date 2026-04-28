# Scenario 03 — Force a REVISE loop

**Status (2026-04-28):** REVISE state machine **validated end-to-end** via manual injection (orchestrator received synthetic `needs-revision`, dispatched engineer revision 1 with correct naming + revision_notes, engineer actually pushed a revision commit, orchestrator re-dispatched qa-review). 6m 17s for one full REVISE cycle.

Three real-spec attempts (basic, strict RFC 7231, multi-file scope with package.json edit) all approved by QA on first try — Sonnet 4.6 is too capable to trip on diff-verifiable specs. **The orchestrator's REVISE branch is correct; we just couldn't trigger it organically with the model in use.**

This page tracks the hypotheses and recipes I'm working through to actually trigger the REVISE state transition end-to-end.

## What forcing a REVISE looks like

```
parent → engineer (writes code, opens PR)
       → ADVANCE → qa-review (reads diff)
       → REVISE → engineer-revision-1 (pushes more commits to SAME branch)
       → ADVANCE → qa-review-revision-1
       → CLOSE  (if approved) OR REVISE again (up to 3 attempts before ESCALATE)
```

The orchestrator's `REVISE` action requires `qa-review` to return:
```json
{ "review_decision": "needs-revision", "revision_notes": ["item 1", "item 2", ...] }
```

## Why it didn't fire on previous runs

QA's `code-review` skill is precise. It reads diffs against literal acceptance criteria. If the engineer satisfies every criterion in the diff, QA approves.

Sonnet 4.6 is good enough that for single-file diff-verifiable specs, it satisfies every criterion. No REVISE.

## Hypotheses (ranked by likelihood-to-work)

### H1 — Multi-file scope where engineer must touch >1 file
Spec requires `app/api/hello/route.ts` AND a corresponding update to `package.json` (e.g., add a `scripts.test:hello` line). Engineer focused on the route file may forget the package.json edit. QA notices via diff inspection.

**Verifiable from diff:** ✅ — both files visible in `gh pr diff`
**Likelihood of triggering REVISE:** medium

### H2 — Implicit acceptance criteria (engineer must infer)
Spec says "the endpoint must work behind nginx without modification." No nginx config exists. Engineer either:
- Ignores it (doesn't realize it's a real constraint) → QA flags as missing
- Adds nginx config → QA flags as scope creep ("modified files outside scope")

Either path forces revision.

**Verifiable from diff:** ✅
**Likelihood of triggering REVISE:** medium-high

### H3 — Conflicting acceptance criteria
Spec includes two requirements that can't both be true (e.g., "response is fully cacheable" AND "Cache-Control: no-store"). Engineer picks one interpretation; QA flags the other as missing.

**Risk:** QA might also be confused and approve anyway.
**Likelihood:** low

### H4 — Spec requires non-existent API
"Use the `Next.js 15 App Router with Edge Runtime` feature for this endpoint" when running Next.js 14. Engineer either invents it or returns `blocked`.

**Likelihood of triggering REVISE:** unclear — engineer may return `blocked` (which routes to ESCALATE, not REVISE)

### H5 — Behavior not visible in the diff
"Endpoint must respond in <50ms under 1000 concurrent requests." No tests exist. QA can't verify from diff. Will probably be flagged as `unverifiable` (we saw this on Scenario 01's lint criterion).

**Likelihood:** low — QA correctly distinguishes "unverifiable" from "missing"

### H6 — Manually-injected REVISE
Skip the engineer entirely; create a qa-review sub-issue manually with a `needs-revision` JSON in its description. Forces the orchestrator's REVISE branch directly.

**Verifies:** the orchestrator's REVISE → engineer dispatch logic
**Doesn't verify:** that qa-review can actually emit needs-revision in the wild
**Useful for:** smoke-testing the orchestrator's state machine

## Planned attempt — H1 (multi-file scope)

```bash
multica issue create \
  --title "Add /api/hello endpoint and register a smoke-check script" \
  --assignee orchestrator \
  --priority medium \
  --description "Add a GET /api/hello endpoint AND register a corresponding smoke-check.

Target repo: /absolute/path/to/multica-sandbox
Remote: origin
Base branch: main

Required deliverables:
1. New file at app/api/hello/route.ts implementing GET returning 200 with {\"hello\":\"world\"}
2. Update package.json to add scripts.smoke=\"curl -fsS http://localhost:3000/api/hello\"

Acceptance criteria:
* Both files modified — no more, no less
* package.json's scripts.smoke must be exactly the string above (no trailing slash on URL, no extra flags on curl)
* package.json's scripts.test, scripts.dev unchanged
* No new dependencies added

Non-goals: no tests, no middleware changes, no other scripts."
```

### Run 3 result (2026-04-28)
**Approved on first try.** Engineer correctly modified BOTH files (`app/api/hello/route.ts` new + `package.json` updated with the smoke script). 5m 51s end-to-end. Real PR: https://github.com/wingtonrbrito/multica-sandbox/pull/4 (now closed). QA verdict: FULL spec compliance, 2 files reviewed.

So Sonnet 4.6 also nails multi-file scope first try. Three negative attempts to force REVISE organically.

---

## Manual REVISE injection (the validation that worked)

Since Sonnet 4.6 didn't trip on any of our diff-verifiable specs, we validated the REVISE state machine independently by **synthesizing a chain manually** — bypass the engineer + qa-review wakes by hand-crafting their handoff comments.

### Method
1. Created a parent issue (no assignee — orchestrator doesn't fire on it yet).
2. Created an `[engineer]` sub-issue under parent. Posted a hand-crafted "completed" handoff comment with a JSON contract block containing a `pr_url`. Closed the engineer sub-issue. (Simulates a finished engineer phase.)
3. Created a `[qa-review]` sub-issue under parent. Posted a hand-crafted **needs-revision verdict** as a comment with `review_decision: needs-revision` and three `revision_notes`. (Simulates QA rejecting the PR.)
4. Reassigned the qa-review sub-issue to orchestrator. **This is the wake signal that triggers REVISE.**

### Result — orchestrator's REVISE state machine fired correctly
| Time | Event | Confirms |
|---|---|---|
| 13:27:36 | Orchestrator wakes on qa-review reassignment | Wake signal works |
| 13:28:53 | Created `[engineer] revision 1 — Add a /api/hello endpoint` | Title naming convention preserved |
| 13:28:59 | Engineer queued | New sub-issue dispatched |
| 13:29:05 | Comment on parent: "qa-review returned needs-revision on PR..." | Parent narrative correct |
| 13:29:07 | qa-review sub-issue flipped to done | Closed alongside REVISE |
| 13:29:15 | Orchestrator's REVISE wake completed | Action terminates cleanly |

The revision sub-issue's description included the three `revision_notes` from the synthetic verdict verbatim, plus the load-bearing rule "push additional commits to the existing PR branch; do NOT open a new PR."

### Bonus: engineer actually pushed a real revision commit
We let the engineer agent run on the revision sub-issue out of curiosity. It correctly:
- Recognized this was a revision cycle (from the description)
- Identified the existing branch (`feature/8e78735e-hello-endpoint`)
- Pushed an additional commit (`fbba831`) addressing two of the three synthetic revision notes
- Posted a clean handoff comment with `status: completed`, reassigning to orchestrator

Orchestrator then dispatched a `[qa-review] Re-review PR after revision 1 — ...` sub-issue (cancelled before completion since the synthetic PR URL pointed at an unrelated closed PR).

**This validates the entire REVISE → engineer revision → ADVANCE → re-review loop end-to-end** at the protocol level. The fact we couldn't trigger it organically with Sonnet 4.6 is a model-capability finding, not a platform-design finding.

### Implications
- The orchestrator's revision-counter logic + "push to existing branch" rule + revision-notes threading are all **correct as documented**. Confirmed empirically.
- Forcing REVISE on Sonnet 4.6 in production likely requires:
  - **Adversarial QA models** (have qa-review use a stricter or differently-trained model than engineer; cross-model review may catch what Sonnet self-misses)
  - **Genuine ambiguity** (multi-week-old context, fuzzy domain knowledge requirements)
  - **Behavioral verification beyond the diff** (running tests, performance budgets, integration checks — none of which our scenarios required)
- David's choice of running QA Review on Codex (GPT-5.4) rather than Claude is exactly the cross-model pattern that would catch what Sonnet's self-review misses. We mapped to Claude for parity reasons; this likely reduces REVISE rate in our setup vs. David's.

## What we'll learn

- If this triggers REVISE: orchestrator's REVISE → engineer-revision-1 → qa-review-revision-1 → CLOSE flow validated end-to-end
- If engineer nails it on first try too: confirms Sonnet 4.6 is robust on multi-file scope, REVISE-forcing requires going to H2/H3
- If QA misses something both should catch: flags a real cross-model review gap (worth bringing to David)

Stay tuned.

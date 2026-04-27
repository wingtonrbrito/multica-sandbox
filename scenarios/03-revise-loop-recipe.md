# Scenario 03 — Force a REVISE loop (work-in-progress)

**Status:** unsolved at the time of this writing. Sonnet 4.6 nailed both [Scenario 01](01-simple-endpoint.md) and [Scenario 02](02-strict-rfc-spec.md) on first try.

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

Will document the actual outcome here once run.

## What we'll learn

- If this triggers REVISE: orchestrator's REVISE → engineer-revision-1 → qa-review-revision-1 → CLOSE flow validated end-to-end
- If engineer nails it on first try too: confirms Sonnet 4.6 is robust on multi-file scope, REVISE-forcing requires going to H2/H3
- If QA misses something both should catch: flags a real cross-model review gap (worth bringing to David)

Stay tuned.

# Scenario 06 — Edge cases

**Status:** E1 (empty description) ✅ tested 2026-04-28. Others remain planned.

Stress-tests the platform's failure modes. Each sub-scenario probes a specific class of broken input or unusual condition.

## E1 — Empty parent description

```bash
multica issue create \
  --title "Empty test" \
  --description "" \
  --assignee orchestrator
```

**Expected:** orchestrator's wake-time guards trigger retry-on-empty (3× × 2s sleep). After 3 consecutive empty reads, returns `status: blocked` with summary explaining empty description.

**Actual (2026-04-28):** orchestrator handled it gracefully but NOT via retry-on-empty — instead, ESCALATEd to `in_review` after a single wake. Posted exactly the right diagnostic comment:

> **[multica · orchestrator]**
> Declining dispatch — issue description is empty, so no specialist can be triaged. Please add a task description (the deliverable, target repo/path, and any scope guardrails) and reassign to me to retry. Flipping to in_review for human attention.

This means: the orchestrator's instructions distinguish "description didn't load yet" (read-after-write race → retry) from "description is genuinely empty" (declining dispatch → ESCALATE). The retry-on-empty guard is for the FIRST case (specialist sub-issue creation race); orchestrator's reactive-mode triage is the SECOND case.

**Lesson:** retry-on-empty applies during sub-issue creation (orchestrator → specialist), not parent issue creation (human → orchestrator). The parent dispatch path is allowed to "fail fast and ESCALATE" because there's no race to wait out — if a human created an empty issue, no amount of polling will fix it.

**What to watch (empirical):** `multica issue runs <parent-id>` shows 1 run that completed cleanly. No retries.

## E2 — Malformed `Target repo` path

```bash
multica issue create \
  --title "Add /api/x to nowhere" \
  --description "Target repo: /tmp/this-path-does-not-exist
Add a /api/x endpoint." \
  --assignee orchestrator
```

**Expected:** orchestrator dispatches to engineer. Engineer wakes, tries to `cd /tmp/this-path-does-not-exist`, fails. Engineer should return `status: blocked` with summary.

Then orchestrator on engineer's handoff sees `blocked` and ESCALATEs. Parent flips to `in_review`.

**What to watch:** does engineer ESCALATE cleanly or crash? Does orchestrator recognize `blocked` as a non-success terminal state?

## E3 — 3 concurrent parents fired at once

```bash
for i in 1 2 3; do
  multica issue create \
    --title "Concurrent test $i" \
    --description "Add /api/test$i with no real spec." \
    --assignee orchestrator &
done
wait
```

**Expected:** orchestrator processes all 3 as separate chains. Daemon serializes spawns per runtime. With 3 in flight and 1 claude runtime, expect:
- All 3 `[engineer]` sub-issues created (orchestrator's runs are fast)
- Engineers serialize on the runtime — only 1 active engineer at a time
- `multica issue runs` shows queued vs dispatched vs started timestamps spread out

**What to watch:** runtime queueing behavior. Does `max_concurrent_tasks` (default 6) gate parallelism?

## E4 — Specialist returns malformed JSON contract

This one's harder to provoke naturally. Manually:
1. Create a sub-issue assigned to engineer.
2. Manually post a comment on the sub-issue WITHOUT a JSON contract block.
3. Manually reassign to orchestrator.

**Expected:** orchestrator parses the comment for trailing JSON via `synthesize-extract` skill, finds nothing, returns PARSE-FAILURE → ESCALATE.

**What to watch:** does the orchestrator's ESCALATE comment clearly explain why?

## E5 — Specialist exits with timeout

The daemon has `MULTICA_AGENT_TIMEOUT` default of 2h. Probing this requires:
- An issue with a task that genuinely takes >2h (unrealistic to manually script)
- OR temporarily setting the daemon's timeout to something tiny (e.g., 30s) and giving an engineer a long task

For a quick probe:
```bash
# Set short timeout via env var
MULTICA_AGENT_TIMEOUT=30s multica daemon restart

# Fire a long-running engineer task
multica issue create \
  --title "Sleep test" \
  --description "Run \`sleep 60\`. Then post a comment." \
  --assignee engineer
```

**Expected:** daemon kills engineer subprocess at 30s. Sub-issue stays in some indeterminate state (still `in_progress`?). Daemon logs the timeout.

**What to watch:** does the daemon retry? Reassign? Close the issue with an error status? This is a known gap in any agent platform — what happens at the edge.

## E6 — Reassignment during active work

While an engineer is mid-execution, manually reassign its sub-issue to a different agent:
```bash
multica issue assign <engineer-sub-id> --to qa-review
```

**Expected:** unclear — does the running engineer process get killed? Does qa-review wake with engineer's partial work visible? This is a race-condition probe.

## E7 — Skill modification while attached agent is running

Same shape as E6 but for skills:
1. Fire issue assigned to alice (with test-skill-v1 attached)
2. While alice is in-flight, modify test-skill-v1 content
3. Does alice's in-flight execution see the change?

(Already covered in [Scenario 05](05-skill-mutation.md) but worth surfacing as an edge case.)

## E8 — Daemon restart during in-flight chain

```bash
# Fire a chain
multica issue create --title "..." --assignee orchestrator

# Wait for engineer to start
sleep 30

# Restart daemon
multica daemon restart
```

**Expected:** running subprocess is presumably killed (daemon is the parent). Sub-issue's run record shows partial completion. Wake-time guard on next assignment cycle... should it re-fire engineer? Or does daemon mark the run as failed and human-escalate?

## E9 — Reviewer extraction with all 3 regex forms + defaulted

New since 2026-04-30: huly-scan v2 parses `Reviewer:` from Huly description with a 3-form regex cascade. This scenario stresses each form.

Use `huly-create-test-issue.mjs` (in `ds-org-suite/scripts/`) to create 4 Huly issues with different Reviewer-line shapes:

```bash
SCRIPT=~/projects/ds-suite/ds-org-suite/scripts/huly-create-test-issue.mjs

# Form 1 — mailto target (Huly autolink)
node "$SCRIPT" --project HULY \
  --title "multica-sandbox test E9.1" \
  --reviewer "[label@x.com](mailto:codingin30@gmail.com)"

# Form 2 — markdown display only (no mailto)
node "$SCRIPT" --project HULY \
  --title "multica-sandbox test E9.2" \
  --reviewer "[codingin30@gmail.com]"

# Form 3 — plain email
node "$SCRIPT" --project HULY \
  --title "multica-sandbox test E9.3" \
  --reviewer "codingin30@gmail.com"

# Form 4 — missing Reviewer line entirely (use --body to override default)
node "$SCRIPT" --project HULY \
  --title "multica-sandbox test E9.4" \
  --reviewer "" \
  --body "Just a body, no Reviewer: line at all"
```

Trigger Huly Scan:

```bash
SCAN_ID=$(multica autopilot list --output json | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('autopilots',[]):
    if a.get('title') == 'Huly Scan': print(a.get('id'))")
multica autopilot trigger "$SCAN_ID"
```

**Expected:** 4 new Multica parents created, each with description shape:
```
Huly: HULY-N
Reviewer: <extracted email | codingin30@gmail.com if defaulted>

<body>
```

Forms 1-3 should resolve to `codingin30@gmail.com` (mailto wins, then markdown display, then plain). Form 4 defaults to `codingin30@gmail.com` (the self-host workspace default per huly-scan DEMO OVERRIDE preamble).

The tick-summary `notes` array on the Huly Scan tracking issue should include 4 lines, each noting which form matched (or "defaulted").

**What this verifies:** the load-bearing chunk of David's huly-scan v2 update — that the Reviewer line is robust to Huly's autolinking quirks.

## E10 — Predecessor-purge under concurrent HULY_SCAN + SWEEP

The purge script's `--older-than-iso` guard guarantees the current tick's anchor survives. But what about two ticks running concurrently — does HULY_SCAN's purge ever race-delete SWEEP's anchor?

Test:

```bash
# Trigger both autopilots within 2 seconds
SCAN_ID=$(multica autopilot list --output json | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('autopilots',[]):
    if a.get('title') == 'Huly Scan': print(a.get('id'))")
SWEEP_ID=$(multica autopilot list --output json | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('autopilots',[]):
    if a.get('title') == 'Orchestrator Sweep': print(a.get('id'))")

multica autopilot trigger "$SCAN_ID"
multica autopilot trigger "$SWEEP_ID"
```

**Expected:** both ticks complete. Both run their Phase 5 cleanup. Each tick's anchor survives because their own `created_at` is excluded by `--older-than-iso=$MY_CREATED` (strict less-than). The second tick to run will find the first tick's anchor as a predecessor (now `done`) and delete it.

```bash
# After both complete, verify steady-state ≤ 2 tracking issues
multica issue list --output json | python3 -c "
import json,sys
n_scan = n_sweep = 0
for i in json.load(sys.stdin).get('issues',[]):
    t = i.get('title','')
    if t == 'Huly Scan': n_scan += 1
    if t == 'Orchestrator Sweep': n_sweep += 1
print(f'Huly Scan: {n_scan}, Orchestrator Sweep: {n_sweep}')"
```

**Pass criteria:** at most 1 of each title remains. (At most 2 if both ticks ran simultaneously and neither was old enough to be the other's predecessor — tolerated.)

**What this verifies:** the idempotent + race-safe properties of `multica-purge-huly-scans.py`.

## E11 — Race-tight pre-check stress on SYNTHESIZE-MULTI

Hardest to provoke organically. Two analysts must complete near-simultaneously such that two parallel orchestrator wakes both reach SYNTHESIZE-MULTI.

Recipe using `multica-pdb.py`:

1. Set up a FAN-OUT parent (e.g., scenario/04-fan-out-multi-analyst test issue) with 3 analyst children all near-completion.
2. Force the third analyst to complete by injecting a synthetic completion JSON into its sub-issue using `multica-pdb.py`:

```bash
# Open pdb on the parent
python3 ~/projects/ds-suite/ds-org-suite/scripts/multica-pdb.py <parent-id>
```

```
> tree                      # confirm fan-out shape
> f <analyst-3-child-id>    # focus the analyst whose status you want to flip
> inject 3                  # synthetic completion JSON
y                           # confirm
```

3. Immediately use a second terminal to simulate the OTHER race-condition entry — flip the second-to-last analyst to `done` via API with a near-simultaneous timestamp.

**Expected:** orchestrator wakes twice (once per analyst handoff). Both reach SYNTHESIZE-MULTI. The race-tight pre-check (David's pattern) catches this:

- Wake A: pre-check sees no synthesizer → creates one → post-create cancel-newer sees only its own → proceeds.
- Wake B (near-simultaneous): pre-check sees Wake A's synthesizer → aborts with comment "Concurrent SYNTHESIZE-MULTI absorbed".

OR if both pre-checks miss the race:
- Both create synthesizer sub-issues.
- Both run post-create cancel-newer. The earlier-created one wins; the later one is flipped to `cancelled`.
- The losing wake emits `status: waiting` with summary "race-loss at SYNTHESIZE-MULTI".

**Pass criteria:** at most 1 synthesizer sub-issue is in non-terminal state at any moment. The `multica issue list` query for `[synthesizer]` titles under the parent should never return >1 non-cancelled child.

**What this verifies:** the load-bearing concurrency guard David shipped. Without it, both wakes would create synthesizer children → both would assign and dispatch → 2x duplicate synthesis work + 2x duplicate Huly comments at CLOSE-MULTI. The cancel-newer cleanup is what makes the chain at-most-once even under tight races.

## What we'll learn

These probes characterize Multica's failure boundaries. Real-world agent platforms hit these edges constantly:
- Daemon crashes mid-chain
- Network drops during a long-running task
- An LLM provider rate-limits the runtime
- A user deletes an issue while an agent is working on it

Knowing how the platform behaves under these conditions is more valuable than another happy-path success story.

## Output

Each sub-scenario will get a "Result" section appended once run. Failures get full reproductions.

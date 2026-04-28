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

## What we'll learn

These probes characterize Multica's failure boundaries. Real-world agent platforms hit these edges constantly:
- Daemon crashes mid-chain
- Network drops during a long-running task
- An LLM provider rate-limits the runtime
- A user deletes an issue while an agent is working on it

Knowing how the platform behaves under these conditions is more valuable than another happy-path success story.

## Output

Each sub-scenario will get a "Result" section appended once run. Failures get full reproductions.

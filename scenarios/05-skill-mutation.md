# Scenario 05 — Skill mutation (planned)

**Status:** planned, not yet run.

Empirically resolves whether modifying a skill mid-flight propagates to the agent's next wake. Closes the last open question on skill scoping (workspace-level vs cached-at-dispatch).

## Hypothesis

Skills are workspace-scoped resources fetched at dispatch time, NOT cached on the agent's runtime. Changes propagate immediately on the next wake.

Evidence pointing this way (from surface inspection):
- Every skill object has `workspace_id` set; `agent_id: null`, no `scope`/`visibility` fields
- `multica skill create` has no agent-scoping flags
- `multica agent skills` exposes only `list` and `set` (atomic full-replace)
- `agent.skills` is a list of IDs (references), not embedded copies

What's still unverified: does the *runtime CLI* (Claude Code, Codex, etc.) cache skill content at process start, or re-read on every tool call?

## Experiment design

### Setup
1. Create a simple skill `test-skill-v1` with content that says "Always reply 'BLUE' as the first word."
2. Create two simple agents `alice` and `bob`, both with `test-skill-v1` attached. Their instructions tell them to follow the attached skill verbatim.
3. Verify both agents reply "BLUE" when given a smoke-test issue.

### Mutation test
4. Modify `test-skill-v1` content to say "Always reply 'RED' as the first word."
5. Fire a fresh smoke-test issue assigned to `alice`. Observe response.
6. Fire same to `bob`. Observe response.

### Re-attach test
7. Detach `test-skill-v1` from `alice` (via `multica agent skills set alice --skill-ids ""`).
8. Fire smoke-test to `alice`. Observe (should fall back to default behavior, no "RED" or "BLUE").
9. Re-attach to `alice`. Fire again. Observe.

### Mid-flight test (most interesting)
10. Fire a longer-running smoke-test to `alice`.
11. While it's in-flight, modify `test-skill-v1` content again.
12. Observe whether `alice`'s in-flight execution sees the old or new content.

## What each result tells us

| Step | Old content | New content | Implication |
|---|---|---|---|
| 5 | "BLUE" | "RED" | Skill content is NOT cached per-agent — fetched on each wake |
| 5 | "BLUE" | "BLUE" | Skill content IS cached somewhere — needs investigation |
| 6 | (alice "RED") | (bob "RED") | Workspace-level scope confirmed — both agents see same change |
| 6 | (alice "RED") | (bob "BLUE") | Per-agent caching is happening |
| 9 | varies | varies | Detach/re-attach behavior |
| 12 | varies | varies | Mid-flight cache vs fresh fetch |

## Why this matters

**For agent platform design:** if skills are re-read on every wake, you can hot-patch behavior across all agents simultaneously. If they're cached, you need to bounce daemons or clear caches.

**For multi-tenant safety:** if `agent skills set` is the only mutation point, you can audit changes via that single API. If skills can drift from what the workspace library shows, that's a coherence bug.

**For David's research question:** this empirically closes question 5 ("mid-flight task behavior") that surface inspection couldn't answer.

## Tooling needed

- A throwaway smoke-test agent (alice/bob)
- A throwaway skill (test-skill-v1)
- Watcher running so we capture the timing
- Trace renderer to compare runs

All available in this sandbox.

## Cleanup

After the experiment:
```bash
multica agent skills set alice --skill-ids ""
multica agent skills set bob --skill-ids ""
multica skill delete <test-skill-v1-id> --yes
multica agent archive <alice-id>
multica agent archive <bob-id>
```

Will document actual results here after running.

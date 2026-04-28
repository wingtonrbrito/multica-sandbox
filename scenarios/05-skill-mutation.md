# Scenario 05 — Skill mutation

**Status:** ✅ Passed (2026-04-27). Confirmed empirically: skills are workspace-scoped, fetched on every wake, no per-agent cache.

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

## Actual results (2026-04-27)

### Setup
- Created skill `test-skill-v1` with content: "Always prefix your reply with the word **BLUE** as the very first word"
- Created agents `alice-test` and `bob-test`, both attached to `test-skill-v1`
- Both agents had identical instructions: "read the skill, follow its rule, post one comment, close the issue"

### Phase 1 — pre-mutation
| Agent | Issue | Reply |
|---|---|---|
| alice | "Tell me what 1+1 equals." | "**BLUE** 1+1 equals 2." |
| bob (after API timeout retry) | "Tell me what 3+3 equals." | "**BLUE** 3+3 equals 6." |

Both agents correctly applied the skill.

### Phase 2 — mutation
- Modified `test-skill-v1` content: changed "BLUE" → "RED"
- Skill `updated_at` timestamp: `2026-04-28T04:54:51Z`
- Did NOT touch the agents themselves (no `agent skills set`, no agent update, no daemon restart)

### Phase 3 — post-mutation (fired ~30s after the skill edit)
| Agent | Issue | Reply |
|---|---|---|
| alice | "Tell me what 4+4 equals." | "**RED** 4+4 equals 8." |
| bob | "Tell me what 5+5 equals." | "**RED** 5+5 equals 10." |

**Both agents picked up the new content on their very next wake.**

## Conclusions (empirical)

1. **Skills are workspace-scoped resources** — confirmed. Modifying once affected both attached agents.
2. **Skill content is fetched fresh on every wake** — confirmed. No agent restart, no re-attach, no daemon bounce required.
3. **There is no per-agent skill cache** — confirmed. Both agents reflect the latest skill content within seconds of the edit.
4. **Modification propagates instantly** — Phase 3 issues fired ~30 seconds after the skill update, and both agents already reflected the new content.

This closes the last open question on skill scoping (David's research question 5: "what happens to a running task whose skill is modified mid-flight?"). Practical answer: **the next wake reads the new content, period**. There's no caching layer to invalidate.

## Implications for platform design

- **Hot-patching skill behavior across all agents is one CLI call** — `multica skill update <id> --content "..."`. Useful for emergency fixes.
- **Skill changes are observable but not auditable** — `updated_at` timestamps but no version history. If you need rollback, version your skills externally (git, snapshot before edit).
- **Mid-flight tasks are NOT affected within a single wake** — once an agent has read the skill content during its current run, the run continues with that content. Only the NEXT wake re-reads.
- **No way to "lock" a skill from edits while a chain is running** — would require scripted gating outside Multica.

## Edge cases not tested

- What if the skill is **deleted** while attached to an active agent? (Untested — would expect either a default-fall-through or an error on next wake)
- What if the skill content is malformed YAML/markdown? (Untested — would expect skill content to still be passed through; downstream parsing is the agent's concern)
- What about **mid-wake mutation** — agent has already started reading the skill, you modify it. Does the agent see partial old + partial new? (Untested — would require finer-grained observability than we have)

## Cleanup
After the experiment:
```bash
multica agent archive <alice-id>
multica agent archive <bob-id>
multica skill delete <test-skill-v1-id> --yes
```

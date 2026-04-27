# Scenarios

Reproducible test runbooks. Each one is a copy/paste-able recipe for a specific Multica chain pattern.

| Scenario | Status | What it tests |
|---|---|---|
| [01 — Simple endpoint](01-simple-endpoint.md) | ✅ Passed | DISPATCH → engineer → ADVANCE → qa-review → CLOSE on basic spec |
| [02 — Strict RFC 7231 spec](02-strict-rfc-spec.md) | ✅ Passed | Same chain shape with hardened acceptance criteria |
| [03 — REVISE loop](03-revise-loop-recipe.md) | 🟡 Unsolved | Recipes for forcing engineer revision (Sonnet 4.6 hard to trip) |
| [04 — FAN-OUT multi-analyst](04-fan-out-multi-analyst.md) | ⏳ Planned | Parallel dispatch to 2+ analysts → SYNTHESIZE-MULTI → CLOSE-MULTI |
| [05 — Skill mutation](05-skill-mutation.md) | ⏳ Planned | Workspace-scoped skills, mid-flight propagation |
| [06 — Edge cases](06-edge-cases.md) | ⏳ Planned | Empty desc, malformed paths, concurrent dispatch, timeouts |

Each runbook follows the same shape:

1. **Setup** — agents/skills/repo prerequisites
2. **The issue** — exact `multica issue create` command (copy/paste)
3. **Watch it** — what to see in the watcher + UI
4. **Expected events** — annotated timeline
5. **Real artifacts** — what gets produced (PRs, comments, sub-issues)
6. **What this proves / does NOT prove** — scope limits

When you run a scenario, append your results to its "Outcome" section. Bug reports go in [`docs/08-upstream-issues.md`](../docs/08-upstream-issues.md).

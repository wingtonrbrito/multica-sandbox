# 06 — Tested Scenarios

The full matrix of what I ran on self-host, what I observed, and what's still pending. Each row links to a reproducible runbook in [`scenarios/`](../scenarios/).

## Scenario summary

| # | Scenario | Outcome | Time | Key observation |
|---|---|---|---|---|
| 01 | Simple endpoint (engineer → QA approved) | ✅ Passed | 6m 11s | Sonnet 4.6 handles single-route Next.js trivially |
| 02 | Strict RFC 7231 endpoint (HEAD/Allow/Vary) | ✅ Passed | 6m 35s | Even hardened criteria don't trip Sonnet 4.6 first try |
| 03 | REVISE loop (force engineer revision) | 🟡 Pending | TBD | Need genuinely ambiguous spec or multi-file scope |
| 04 | FAN-OUT multi-analyst panel | 🟡 Pending | TBD | `Analyst panel: arch, security, data` triggers parallel dispatch |
| 05 | Skill mutation mid-flight | 🟡 Pending | TBD | Confirms workspace-level scoping; tests cache vs re-fetch |
| 06 | Edge cases (empty desc, malformed, concurrent) | 🟡 Pending | TBD | Probes failure modes |

## Detailed observations

### Scenario 01 — Simple endpoint
**Spec:** `GET /api/hello` returning `{"hello": "world", "timestamp": "<ISO8601>"}`. Acceptance criteria: new file at correct path, Content-Type header, OPTIONS handler, X-Powered-By header.

**Result:** First run approved on first try. QA flagged "lint passes" as unverifiable (no lint config in sandbox repo). All other criteria satisfied.

**Chain shape:**
```
parent → [engineer] → ADVANCE → [qa-review] → CLOSE
```

**Lesson:** the protocol works end-to-end; producing a real PR + real review on first try is achievable with Sonnet 4.6.

### Scenario 02 — Strict RFC 7231 semantics
**Spec:** Add explicit HEAD export, OPTIONS handler, 405 catch-alls for unsupported methods. Every non-204 response must include Vary, Cache-Control, X-Powered-By, Content-Type. JSON key ordering specified.

**Result:** Approved on first try, FULL spec compliance. Engineer correctly:
- Exported HEAD even though Next.js handles it automatically
- Included `Allow: GET, HEAD, OPTIONS` header on 405 responses (RFC 7231 mandatory)
- Included `Vary: Accept` on every non-204 response
- Used `NextResponse` from `next/server`, not the older `Response` API
- Maintained JSON key order (`hello` before `timestamp`)

**Real output:** [`examples/api-hello-route.ts`](../examples/api-hello-route.ts)

**Lesson:** writing diff-verifiable acceptance criteria isn't enough to force REVISE on Sonnet 4.6. To trigger the revision path, you need either:
- Genuine ambiguity (two reasonable interpretations, only one matches)
- Multi-file scope where engineer must touch >1 file correctly
- Behavior verifiable only outside the diff (test coverage thresholds, runtime invariants)

### Scenario 03 — REVISE loop
**Status:** open. Best ideas pending:
- Specify behavior the engineer can't verify locally — e.g., "must not regress against existing tests" when no tests are in the repo (engineer adds tests; QA flags as scope creep)
- Multi-file scope — "add the route AND update package.json's scripts.test to run a smoke check"
- Implicit conflict — "new endpoint must work behind nginx without modification" (no nginx config in repo; engineer either ignores or asks)

Will document the recipe that actually trips the loop in [`scenarios/03-revise-loop-recipe.md`](../scenarios/03-revise-loop-recipe.md).

### Scenario 04 — FAN-OUT multi-analyst
**Status:** open. Plan:
- Parent issue: "Review repo X for arch + security + data concerns"
- Description includes `Analyst panel: arch, security, data` (case-insensitive prefix; this triggers FAN-OUT triage on the orchestrator)
- Three sub-issues created in parallel
- All three must complete before SYNTHESIZE-MULTI fires
- Synthesizer combines findings into a unified report
- CLOSE-MULTI closes the parent

### Scenario 05 — Skill mutation
**Status:** open. Hypothesis: skills are workspace-scoped resources fetched at dispatch time (NOT cached on the agent). Experiment design:

1. Attach skill `X` to two agents A and B
2. Fire issue assigned to A — captures pre-mutation behavior
3. While issue is in-flight, modify skill `X` content
4. Fire same issue type to B — should reflect new content
5. (Optional) wake A again on a fresh issue — should also reflect new content

Confirms or refutes whether skill content is cached per-process at dispatch time.

### Scenario 06 — Edge cases
**Status:** open. Planned probes:
- **Empty description** — fire parent with empty `--description`. Does retry-on-empty kick in? What does the orchestrator return?
- **Malformed `Target repo` path** — point at a non-existent path. Engineer should return `blocked` cleanly.
- **Concurrent dispatch** — fire 3 parents simultaneously. Daemon should serialize per runtime; check queue behavior.
- **Stuck specialist** — kill the agent process mid-run. Does the daemon retry? Time out?

## Things I have NOT tested (but think work)

- **Cross-machine runtimes** — David's setup has runtimes on multiple machines (AMDHome + my Mac). Per his issue history, this works. I haven't tested it directly.
- **Codex runtime as QA reviewer** — David runs QA on Codex deliberately for cross-model review. I had to map QA to Claude (no local Codex). Pattern is intentional and worth preserving.
- **Huly autopilot ingestion** — David's `huly-scan` autopilot pulls tickets from Huly into Multica. Requires Huly + huly-mcp. Public huly-mcp servers exist (npm `@zubeidhendricks/huly-mcp-server`); I haven't wired one up yet.
- **Long-running tasks (>2 hour agent timeout)** — daemon's default `--agent-timeout` is 2h. Haven't probed what happens at the boundary.
- **Webhook external triggers** — autopilots can fire on external triggers, not just schedules. Not tested.

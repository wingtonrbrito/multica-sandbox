# 06 — Tested Scenarios

The full matrix of what I ran on self-host, what I observed, and what's still pending. Each row links to a reproducible runbook in [`scenarios/`](../scenarios/).

## Scenario summary

| # | Scenario | Outcome | Time | Key observation |
|---|---|---|---|---|
| 01 | Simple endpoint (engineer → QA approved) | ✅ Passed | 6m 11s | Sonnet 4.6 handles single-route Next.js trivially |
| 02 | Strict RFC 7231 endpoint (HEAD/Allow/Vary) | ✅ Passed | 6m 35s | Even hardened criteria don't trip Sonnet 4.6 first try |
| 03 | REVISE loop (force engineer revision) | 🟡 Pending | TBD | Need genuinely ambiguous spec or multi-file scope |
| 04 | FAN-OUT multi-analyst panel | ✅ Passed | 13m 32s | Parallel dispatch + synthesizer worked end-to-end. Found 2 real bugs in this very repo. |
| 05 | Skill mutation mid-flight | ✅ Passed | <2 min | Empirically confirmed: workspace-scoped, fetched on every wake, no per-agent cache |
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
**Status:** ✅ Passed. 13m 32s end-to-end. arch-analyst + security-analyst dispatched in parallel; both completed before SYNTHESIZE-MULTI fired; synthesizer produced a unified Platform Analysis Report; CLOSE-MULTI closed everything.

**Bugs the agents found in this very repo (and we fixed in the same commit):**
1. **security-analyst** — `scripts/multica-watch.sh:28-30` used a predictable `$TMPDIR/multica-watch-$$` directory with a `trap 'rm -rf' EXIT`. On shared-tmp Linux hosts, this is CWE-377/379/59 symlink-attack vector. Fix: `mktemp -d`.
2. **arch-analyst** — `docs/02-cheatsheet.md:163` referenced a non-existent `scripts/multica-clone-from-snapshot.py`. Phantom file. Fix: rewrite the reference.

**Synthesizer cross-cutting insight:** the two operational scripts (~200 LOC) concentrate almost all material findings from both lenses, despite being a minority of repo LOC. Recommendation: a single small "scripts-hardening" PR closes most residual risk. This kind of cross-lens insight is what synthesis adds over reading individual analyst reports.

Full results in [`scenarios/04-fan-out-multi-analyst.md`](../scenarios/04-fan-out-multi-analyst.md).

### Scenario 05 — Skill mutation
**Status:** ✅ Passed. Hypothesis confirmed empirically: skills are workspace-scoped, fetched fresh on every wake, no per-agent cache.

**Method:** created `test-skill-v1` with content "always start your reply with BLUE", attached to two test agents (alice + bob), fired pre-mutation issues — both agents replied with "BLUE …". Then modified the skill content to "always start with RED" — did NOT touch the agents. Fired fresh issues — both agents replied with "RED …" within 30 seconds of the edit.

**Implication:** hot-patching agent behavior across an entire workspace is one CLI call (`multica skill update <id> --content "..."`). Useful for emergency fixes. The flip side: there's no skill-version concept, no rollback unless you snapshot externally.

Full results in [`scenarios/05-skill-mutation.md`](../scenarios/05-skill-mutation.md).

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

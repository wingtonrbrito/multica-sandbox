# Pattern — PR-comment loop (PR review → REVISE)

After a Multica chain opens a GitHub PR, a human reviewer may post a review comment on the PR requesting changes. Multica should pick that comment up and route it back into the chain as a REVISE — same shape as the existing qa-review-driven REVISE, just sourced from a GitHub PR comment instead of an internal QA agent.

Buildable now since `add_comment` shipped in PR #3 against `kwhittenberger/huly-mcp-server`.

## Topology

```
Reviewer posts a PR review comment ("rename the var, fix the error msg, ...")
    │
    ▼ Pr-Comment-Audit autopilot polls every 2 min
    │   - Lists PRs Multica opened in repos with branch prefix `multica/`
    │   - For each PR, fetches comments since last scan (timestamp tracked in tick description)
    │   - Filters to comments with prefix [revise] or label "needs-revision"
    ▼
    For each matching new comment:
    │   - Resolve PR → Multica parent via the PR body's `Multica: <id>` line (engineer puts this there)
    │   - If parent's status is done — re-open it (status flip in_review → in_progress)
    │   - Create REVISE sub-issue with the comment body as the revision_notes input
    ▼
Engineer agent picks up the REVISE → makes changes → pushes a new commit to the same PR branch
    │
    ▼ qa-review re-validates → CLOSE-qa-approved → huly-writeback → Huly ticket Todo + reassign reviewer
```

## Why use a polling autopilot, not a GitHub webhook?

A real GitHub webhook → Multica integration depends on the outbound webhook RFC at [`docs/rfcs/webhook-on-transition.md`](../rfcs/webhook-on-transition.md) (which is *outbound* from Multica) plus an *inbound* GitHub-webhook receiver in Multica. Both are upstream-blocked.

Polling is uglier but it works today on top of the existing `Autopilot` primitive. Cost is one `gh api` call per PR per tick; well within rate limits at our scale.

## Components

### 1. `Pr-Comment-Audit` autopilot

```
Title: Pr-Comment-Audit
Schedule: every 2 min (cron: */2 * * * *)
Mode: create_issue
Description:
  Scheduled PR_COMMENT_AUDIT tick. No reactive issue context. Run the procedure:

  1. List Multica issues with title prefix "[engineer]" and any non-cancelled status.
     For each, extract its parent's pr_url (from the engineer's most-recent comment JSON).
     Build the candidate set: distinct (parent_id, pr_url) tuples.
  2. For each (parent, pr_url), call `gh api repos/<owner>/<repo>/pulls/<n>/comments`
     and `gh api repos/<owner>/<repo>/issues/<n>/comments` (PR REVIEW comments + general
     issue-style comments — both planes).
  3. Filter to comments with body prefix `[revise]` (case-insensitive) OR comments by users
     with "reviewer" role posted SINCE the parent's last comment timestamp on Multica.
     Skip bot-authored comments (multica-bot + the engineer's noreply identity).
  4. For each filtered comment, idempotency-check: search Multica for any sub-issue under
     this parent with title prefix `[engineer-revise]` AND created_at >= comment.created_at.
     If a match exists, skip (already filed).
  5. Create REVISE sub-issue under the parent: title `[engineer-revise] <truncated comment subject>`,
     description includes pr_url, comment URL, and the comment body verbatim as revision_notes.
     Assign to engineer.
  6. Phase 5: flip THIS tick-tracking issue to done; run predecessor-purge.
  7. Emit tick-summary JSON. Do NOT run reactive DISPATCH on this wake.
```

### 2. New triage rule in orchestrator instructions

The audit creates the sub-issue directly (not the orchestrator). But the orchestrator needs to know how to handle the new `[engineer-revise]` title prefix when the engineer hands BACK from a comment-driven revise:

> If the handing-back child's title starts with `[engineer-revise]`:
> - On engineer success (`status: completed` with new commit pushed → JSON includes `pr_url` of the same PR): post a comment to the original PR via huly-writeback's `huly-mirror-comment` extension or directly via the `gh` tool — `Revise applied. New commit: <sha>`. Re-route to qa-review with the original revision_notes context for re-validation.
> - On engineer failure: ESCALATE per existing rules.

### 3. Engineer skill update

The engineer's `feature-implementation` skill needs a small extension:

> When handed an `[engineer-revise]` sub-issue under a parent that already has an open PR:
> - Do NOT create a new branch. Check out the existing PR branch (`gh pr checkout <pr-num>`).
> - Apply the revision_notes as in-place edits.
> - Commit + push to the same branch (no new PR).
> - Hand back with `pr_url` matching the existing PR.

This is a 1-paragraph addition; the rest of the skill is already revise-friendly because the existing qa-review-driven REVISE has the same flow.

### 4. Engineer noreply identity

Engineer commits already use `4412238+wingtonrbrito@users.noreply.github.com` (see UPSTREAM-CONTRIBUTIONS.md). The audit MUST skip comments from this email so engineer's own PR comments (e.g., "Pushed revision applied — ready for re-review") don't trigger an infinite revise loop.

## Idempotency story

Three layers protect against double-processing:

1. **Per-comment dedup** in step 4 of the audit (existing `[engineer-revise]` sub-issue with `created_at >= comment.created_at`).
2. **Per-tick cap:** at most 5 REVISE sub-issues per audit tick. Overflow rolls into the next tick.
3. **Engineer revision cap (existing):** 3 engineer dispatches per parent. Repeated PR comment cycles past the cap → ESCALATE.

## Worked example

Reviewer wingtonrbrito reviews the engineer-opened PR for AIP-50 (`Add /api/practice-1 endpoint`). Posts a review comment:

> [revise] The endpoint should return `{"status":"ok","ts":"<ISO8601>"}` per the original ask, not just `{"status":"ok"}`. Also wrap the handler in the existing logger middleware.

Trace (assuming Pr-Comment-Audit autopilot is active):

1. Within 2 min, `Pr-Comment-Audit` ticks. Finds the PR (AIP-50's `pr_url` from engineer comment), pulls comments since AIP-50's last Multica comment.
2. Sees the `[revise]` prefix → creates `[engineer-revise] PR comment review` sub-issue under AIP-50, assigned to engineer. Description includes the comment body verbatim and the PR URL.
3. Engineer wakes on the new sub-issue. `gh pr checkout 1`, edits `routes/practice-1.ts`, commits, pushes to same branch. Hands back with the unchanged `pr_url`.
4. Orchestrator sees `[engineer-revise]` → routes to qa-review for re-validation.
5. qa-review approves → CLOSE-qa-approved.
6. huly-writeback posts a synthesis comment to HULY-X and flips it to Todo + reassigns reviewer.

## What this DOESN'T do

- **In-line code suggestions** (GitHub's `pull_request_review_comments` with `position` / `commit_id` / `path` / `line`). The pattern processes the comment BODY only. Inline comments could be added later; for now, reviewers paste their request prose into a top-level review comment.
- **Per-file revise routing.** A comment hits the whole PR → engineer makes whatever edits make sense. No file-specific dispatch.
- **Auto-merge.** qa-approved PRs still need a human (or external tooling) to merge. Multica's CLOSE doesn't merge; it signals the chain is complete.

## Status

Pattern designed. Implementation deferred until after the round-trip e2e test ships. Dependencies:

- `add_comment` tool in huly-mcp-server (DONE — PR #3 against kwhittenberger).
- `gh` CLI in engineer's allowedTools (DONE — already there for PR creation).
- Orchestrator instructions extension (~50 lines).
- New autopilot.

Estimated effort: ~3 hours including a successful round-trip with one revise cycle.

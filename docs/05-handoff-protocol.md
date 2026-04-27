# 05 — Handoff Protocol

How specialist agents pass work to each other (and back to the orchestrator). The protocol that makes specialists composable.

## The contract — 3 rules

1. **Every specialist's last comment ends with a fenced JSON block.** The orchestrator parses that block, not the narrative.
2. **Status flip + reassignment to the next assignee is the wake signal.** Comments alone do nothing.
3. **The wake-time terminal-state guard runs first.** If the issue is already done/cancelled/in_review, exit no-op immediately.

That's the protocol. Everything else is nuance.

## The JSON contract block

Every specialist hands back via:

```bash
multica issue comment add <SUB_ISSUE_ID> --content "$(cat <<'EOF'
<your narrative — what you did, what you found, in full markdown>

\`\`\`json
{
  "status": "completed",
  "<role-specific-fields>": "...",
  "summary": "One-paragraph human-readable summary",
  "notes": []
}
\`\`\`
EOF
)"

multica issue assign <SUB_ISSUE_ID> --to <next-assignee>
```

Critical: **the JSON block goes INSIDE the comment body**, not just at the end of your model output. The orchestrator reads comment content via `multica issue comment list`, not your model response.

## Common JSON shapes

### Engineer
```json
{
  "status": "completed",
  "pr_url": "https://github.com/<org>/<repo>/pull/<n>",
  "summary": "What I built and how",
  "notes": []
}
```

`pr_url` is required when `status: completed`. Orchestrator's ADVANCE step uses it to populate the qa-review sub-issue.

### QA Review
```json
{
  "status": "completed",
  "pr_url": "https://github.com/...",
  "review_decision": "approved",
  "revision_notes": [],
  "summary": "Verdict: approved. Reason: ..."
}
```

If `review_decision: needs-revision`, `revision_notes` MUST be a non-empty list of concrete actionable items, one per entry — each must be self-contained because they get pasted directly into the engineer's revision sub-issue.

### Read-only analyst (arch / security / data)
```json
{
  "status": "completed",
  "pr_url": null,
  "summary": "What I found",
  "findings_count": 3,
  "notes": []
}
```

### Synthesizer
```json
{
  "status": "completed",
  "summary": "Unified rollup of N analysts: ...",
  "report_url": null,
  "notes": []
}
```

### Universal status values
- `completed` — work done, payload above is the deliverable
- `blocked` — can't proceed (missing input, ambiguous ask) — explain in `summary`
- `error` — tool failure — explain in `summary`
- `needs-human` — task requires judgment specialist shouldn't make — explain in `summary`

## Why reassignment, not comments

Multica's wake model: the daemon polls for assignments. **Agent-authored comments do not change `assignee_id`** — so they don't trigger a wake on the assignee.

This is a feature, not a bug:
- Specialists can post intermediate progress comments without spamming wakes
- The orchestrator sees explicit handoff intent (reassignment) vs incidental updates
- Race conditions are simpler — only one event type matters for state transitions

If you forget to reassign at the end of your work, your chain just stops. Orchestrator never wakes. The sub-issue sits at `todo` forever. (Actually until someone manually intervenes or the orchestrator is woken by something else.)

## The wake-time terminal-state guard

Top of every specialist's instructions:

```
On EVERY wake, BEFORE any other work, check your assigned issue's current status:
- If status is `in_review`, `done`, or `cancelled` → exit immediately with status: completed,
  summary: "Wake on already-terminal issue; no-op."
```

Why: the orchestrator's CLOSE action sometimes reassigns a closed sub-issue back to the specialist as part of its closure procedure. Without this guard, the specialist would re-run its work on a done issue → infinite loop.

## The retry-on-empty-description guard

Multica has a read-after-write race: when an orchestrator creates a sub-issue and assigns it, the specialist's wake can fire BEFORE the description field is readable.

The fix lives in every specialist's prompt:

```
If your first `multica issue get <id>` returns empty/null description,
sleep 2 seconds, retry. Up to 3 total attempts.
Only after 3 consecutive empty reads, return status: blocked.
```

Skipping this guard = `status: blocked` errors that look like real failures but are just race conditions.

## The race-safe sub-issue creation pattern

The orchestrator's `create-sub-issue-safely` skill encodes this sequence to mitigate the read-after-write race:

```bash
# 1. Build description in a tempfile (multi-line content with --description flag is fragile)
echo "<long description>" > /tmp/desc.txt

# 2. Create WITHOUT --assignee
sub_id=$(multica issue create \
  --title "[engineer] ..." \
  --description "$(cat /tmp/desc.txt)" \
  --parent "$PARENT_ID" \
  --output json | jq -r '.id')

# 3. Verify description is readable
multica issue get "$sub_id" --output json | jq -r '.description' | grep -q "<known-substring>"

# 4. Verify status is todo
multica issue get "$sub_id" --output json | jq -r '.status'   # expect "todo"

# 5. THEN assign (this is what wakes the assignee)
multica issue assign "$sub_id" --to "<role>"
```

Five steps; skipping any of them produces flaky failures.

## Self-check before posting the handoff comment

Before calling `multica issue comment add`, validate your output string:

```bash
# Does the last ~300 chars include the fenced JSON block?
echo "$COMMENT_BODY" | tail -c 300 | grep -q '```json'
```

If you skip this check and your model truncates the JSON block, the orchestrator returns `PARSE-FAILURE` and escalates the chain to a human. This has caused real outages.

## What NOT to do

- Don't post on the parent issue — only the orchestrator does that. Cross-issue traffic is the orchestrator's job.
- Don't strip the JSON block "to clean up the narrative" — it's the contract.
- Don't try to merge or close issues yourself (other than your own assignment) — orchestrator owns terminal state.
- Don't invoke any cross-system writeback (Huly, Slack, GitHub merge) — orchestrator owns those.
- Don't open a new PR on a revision cycle — push to the existing branch.

## Putting it all together — engineer's full handoff

```bash
# Top of engineer's wake — terminal-state guard
status=$(multica issue get "$ID" --output json | jq -r '.status')
[ "$status" = "todo" ] || [ "$status" = "in_progress" ] || exit 0

# Read description with retry guard (omitted for brevity)

# ... do the work: branch, code, commit, push, gh pr create ...

# Build comment body with mandatory JSON block
cat > /tmp/handoff.md <<'EOF'
Created `app/api/hello/route.ts` with the requested endpoint.
Branched from main, pushed feat/api-hello, opened PR.

```json
{
  "status": "completed",
  "pr_url": "https://github.com/wingtonrbrito/multica-sandbox/pull/3",
  "summary": "Added GET /api/hello with full RFC 7231 semantics. Single-file change.",
  "notes": []
}
```
EOF

# Self-check: JSON block present in last 300 chars
tail -c 300 /tmp/handoff.md | grep -q '```json' || { echo "missing JSON block"; exit 1; }

# Post comment + reassign back to orchestrator
multica issue comment add "$ID" --content "$(cat /tmp/handoff.md)"
multica issue assign "$ID" --to orchestrator
```

That's a complete handoff. Replicate the shape across every specialist and the protocol holds.

# 04 — Orchestrator State Machine

When you build a multi-agent platform on Multica, your orchestrator agent ends up being a **deterministic finite state machine**. Every wake, it reads the tree (parent + sub-issues + their statuses + their last-comment JSON), decides which transition it's in, applies the action, and exits.

Naming the transitions explicitly makes the system debuggable. Here's the canonical vocabulary.

## The named actions

| Action | When it fires | What the orchestrator does |
|---|---|---|
| **DISPATCH** | Top-level parent has no sub-issues yet | Triages the ask → creates one specialist sub-issue → posts a "dispatched to X" comment on parent |
| **FAN-OUT DISPATCH** | Top-level parent's description has `Analyst panel: <list>` | Creates one sub-issue per analyst in the panel (parallel) |
| **ADVANCE** | Engineer returns `status: completed` with `pr_url` | Closes engineer sub-issue → creates qa-review sub-issue with PR URL → reassigns to qa-review |
| **REVISE** | qa-review returns `review_decision: needs-revision` with `revision_notes` | Creates `[engineer] revision N — ...` sub-issue with notes → assigns to engineer (engineer pushes more commits to the EXISTING branch) |
| **HANDOFF** (analyst) | A read-only analyst returns `status: completed` | Closes analyst sub-issue. If single-analyst chain → CLOSE. If part of FAN-OUT → check siblings. |
| **SYNTHESIZE-MULTI** | All analysts in a FAN-OUT panel are `done` | Creates synthesizer sub-issue with `Contributing sub-issues: ...` block → assigns to synthesizer |
| **CLOSE** | qa-review approved, or single-specialist done, or synthesizer done | Posts summary comment on parent → flips parent to `done` |
| **CLOSE-MULTI** | Synthesizer returns rolled-up findings | Same as CLOSE but also handles multi-analyst sibling closure |
| **WAITING** | Specialists still working, nothing new to act on | Posts a status comment ("waiting on N specialists") and exits cleanly |
| **ESCALATE** | Revision cap reached, parse failure, malformed JSON, or specialist returned `needs-human` | Flips parent to `in_review`, posts a clear "human needed because X" comment, exits |
| **PARSE-FAILURE** | Specialist's last comment is missing the JSON contract block | Treated as ESCALATE — orchestrator can't act on un-parseable output |
| **ANOMALY** | Tree state is logically impossible (all sub-issues terminal but parent not) | ESCALATE with anomaly explanation |

## Why named actions matter

Could you build this without giving each transition a name? Yes. Should you? No. Here's why:

### 1. Stateless wakes need decidable inputs
Every wake has to figure out "which transition am I in?" from current tree state alone. Naming the actions = enumerable set of outcomes from one big switch statement. Without names, it's an implicit tangle of conditionals that drifts as you add specialists.

### 2. Bounded loops require counting transitions
Revision cap: 3 engineer attempts before ESCALATE. Counting requires distinguishing REVISE from DISPATCH. If both look like "create new engineer sub-issue," you can't enforce the cap.

### 3. Upstream mirroring (Huly, Linear, etc.) needs pattern-matching
A `huly-writeback` skill takes `TRANSITION=DISPATCH|ADVANCE|REVISE|CLOSE|ESCALATE` as input and produces the right comment + status update on the source-of-truth ticket. Without distinct transition names, you can't write back coherently.

### 4. Auditability
Reading a chain's history, you should be able to say "this issue was DISPATCH-ed, then ADVANCE-d, then REVISE-d twice, then CLOSE-d." That sentence requires the vocabulary.

### 5. Specialists hand off in different shapes
Engineer returns `pr_url`. QA returns `review_decision`. Analysts return findings. Each handoff requires a different orchestrator action on the receiving end. Distinct names make the dispatch logic clean.

## The state-machine reduction

Conceptually:

```
state = (parent, [sub_issues], [their_statuses], [their_last_json_payloads])
action = decide(state)              # the named-actions switch
apply(action)                        # CLI side effects
exit                                 # wait for next wake
```

Each wake is one reducer call. Each named action is an edge in the state machine. The transitions you actually implement = the depth of your platform.

## Common gotchas at the state-machine layer

### Two specialists handing back at near-the-same-time
Both reassign to orchestrator within seconds. Daemon serializes these via runtime polling, but you might get one wake that sees BOTH handoffs ready. Your decision logic should handle "multiple sub-issues just transitioned" — usually by processing one transition per wake and re-firing on next wake.

### Read-after-write race
A freshly-created sub-issue may not have its `description` field readable yet. Specialists need a retry-on-empty guard (3 attempts × 2 second sleep). The orchestrator's `create-sub-issue-safely` skill mitigates this by creating without assignee first, verifying description is readable, then assigning.

### Wake on already-terminal issue
An assignment to a `done` or `cancelled` issue still wakes the assignee. Every agent (including the orchestrator) needs a wake-time terminal-state guard at the very top of its instructions: "if status is done/cancelled/in_review, exit no-op."

### Revision title pattern
The convention is `[engineer] revision N — <parent's task summary>`. Keep `revision N` parseable so you can count attempts for the cap.

### "Push to existing branch" rule for revisions
The engineer specialist must NOT open a new PR on a revision cycle. The orchestrator has to explicitly include "push additional commits to the existing PR branch" in the revision sub-issue description. Easy to forget; load-bearing.

## A minimal orchestrator state machine — pseudocode

```
on wake:
    issue = multica issue get $ASSIGNED_ID
    if issue.status in [done, cancelled, in_review]: exit
    if issue.parent_id == null:
        # I'm assigned to a top-level parent
        children = list children where parent_id = issue.id
        if children empty:
            return DISPATCH(triage(issue.description))
        if all children terminal:
            if any child returned needs-revision: return REVISE
            if any child returned approved: return CLOSE
            return ANOMALY
        return WAITING
    else:
        # I'm assigned to a child — a specialist just handed back
        last_json = parse_trailing_json(issue.last_comment)
        if last_json == null: return PARSE-FAILURE
        if last_json.status == "needs-human": return ESCALATE
        if child_role == engineer and last_json.pr_url: return ADVANCE
        if child_role == qa-review:
            if last_json.review_decision == "approved": return CLOSE
            if last_json.review_decision == "needs-revision":
                if revision_count >= 3: return ESCALATE
                return REVISE
        if child_role == analyst:
            if part of FAN-OUT and not all siblings done: return WAITING
            if all FAN-OUT siblings done: return SYNTHESIZE-MULTI
            return CLOSE
        if child_role == synthesizer: return CLOSE-MULTI
        return ANOMALY
```

That's the whole reducer. Add specialists by extending the role-handling branches.

## What this gives you

A platform where:
- Every chain has a finite, knowable set of states
- New specialists can be added without rewriting dispatch logic
- Failures cleanly escalate to humans instead of looping
- Audit trails are complete (every transition is named in a comment)
- Revision cycles are bounded (3 attempts before giving up)
- Cross-system mirroring (Huly, Slack, etc.) works by pattern-matching transitions

It's just a state machine. Made of system prompts.

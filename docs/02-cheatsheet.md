# 02 — Cheat Sheet

The `multica` CLI commands I reach for most often, organized by what I'm trying to do. Tested against `multica` 0.2.13.

## Daemon health

```bash
multica daemon start
multica daemon stop
multica daemon status                 # pid, uptime, registered agents, workspaces
multica daemon restart

# Logs (tailable)
tail -f ~/.multica/daemon.log

# Profile-isolated daemon (e.g., a second one against a different server)
multica --profile cloud daemon start
multica --profile cloud daemon status
```

## Runtimes (the local agent CLIs)

```bash
multica runtime list                  # what's registered, online status
multica runtime list --output json | jq '.[]|{name,provider,status}'

# Get a specific runtime ID for use in agent create
multica runtime list --output json | jq -r '.[]|select(.provider=="claude")|.id'
```

## Workspaces

```bash
multica workspace list
multica workspace get <id>
multica workspace members <id>
```

## Agents

```bash
multica agent list                                    # workspace-scoped
multica agent get <id> --output json                  # full detail (instructions, custom_args, custom_env, etc.)
multica agent create \
  --name "<name>" \
  --description "<one line>" \
  --runtime-id "<runtime-uuid>" \
  --model "claude-sonnet-4-6" \
  --visibility workspace \
  --instructions "<system prompt>" \
  --custom-args '["--allowedTools", "Bash", "Read", "Write"]'
multica agent update <id> --instructions "<new prompt>"
multica agent update <id> --custom-args '[...]'
multica agent archive <id>
multica agent restore <id>
multica agent skills list <id>                        # which skills are attached
multica agent skills set <id> --skill-ids "<id1>,<id2>"   # ATOMIC FULL REPLACE
multica agent tasks <id>                              # issue history for this agent
```

**Caveat:** `multica agent create` has no `--custom-env` flag. Set env vars via the UI Environment tab (or direct API call). [Upstream PR pending](08-upstream-issues.md#gap-1).

## Skills

Skills are **workspace-scoped**, not per-agent. The agent.skills list is just a reference set.

```bash
multica skill list                                    # the workspace library
multica skill get <id> --output json | jq '.content'  # full SKILL.md body
multica skill create \
  --name "code-review" \
  --description "Pre-merge PR review skill" \
  --content "$(cat /path/to/SKILL.md)"
multica skill update <id> --content "$(cat new-version.md)"
multica skill delete <id> --yes
multica skill import <url>                            # from clawhub.ai or skills.sh
```

## Issues

```bash
multica issue list                                    # all open in workspace
multica issue list --output json | jq '.issues[]|select(.title|contains("Add"))'
multica issue get <id>
multica issue create \
  --title "<title>" \
  --description "<body>" \
  --assignee "<agent-name-or-member-name>" \
  --priority medium \
  --parent "<parent-id>"
multica issue update <id> --description "<new>"
multica issue assign <id> --to "<agent-name>"
multica issue assign <id> --unassign
multica issue status <id> <new-status>                # POSITIONAL — easy to forget
                                                       # statuses: todo, in_progress, in_review, done, cancelled
multica issue comment list <id>
multica issue comment add <id> --content "<markdown>"
multica issue runs <id>                               # all agent invocations on this issue
multica issue run-messages <task-id>                  # individual messages within a run
multica issue search "<query>"
```

## Autopilots (scheduled triggers)

```bash
multica autopilot list
multica autopilot get <id>                            # includes triggers
multica autopilot create \
  --title "Hourly scan" \
  --description "..." \
  --execution-mode create_issue \
  --assignee orchestrator
multica autopilot trigger <id>                        # manual fire (skips schedule)
multica autopilot runs <id>                           # execution history
```

## Common workflows

### Find a running chain
```bash
# Issues currently being worked on
multica issue list --output json | jq '.issues[]|select(.status=="in_progress")|{id,title,assignee_id}'
```

### Trace a chain end-to-end (any issue + descendants)
```bash
scripts/multica-trace-issue.py <issue-id>             # see scripts/ in this repo
```

### Watch the workspace live
```bash
scripts/multica-watch.sh                              # streams new issues, status changes, comments
```

### Snapshot a workspace
```bash
multica agent list      --output json > agents.json
multica skill list      --output json > skills.json
multica issue list --limit 200 --output json > issues.json
multica autopilot list  --output json > autopilots.json
multica runtime list    --output json > runtimes.json
```

### Reproduce a workspace from a snapshot
```bash
# Skills first (so agents can reference them)
for skill in skills.json/*; do
  multica skill create --name "$(jq -r .name $skill)" \
                       --description "$(jq -r .description $skill)" \
                       --content "$(jq -r .content $skill)"
done

# Then agents
for agent in agents.json/*; do
  multica agent create --name "$(jq -r .name $agent)" \
                       --runtime-id "$(jq -r .runtime_id $agent)" \
                       --instructions "$(jq -r .instructions $agent)" \
                       --custom-args "$(jq -c .custom_args $agent)"
  # custom_env via UI — CLI doesn't have a flag (yet)
done
```

A reusable Python version of this cloning is in `scripts/multica-clone-from-snapshot.py` in this repo.

## Output formats

Every command supports `--output json`. Pair with `jq` for scripting:

```bash
multica issue list --output json | jq -r '.issues[]|"\(.identifier)\t\(.status)\t\(.title)"'
```

## Profile-isolated configs (run two daemons against different servers)

```bash
# Default profile uses ~/.multica/config.json
multica daemon start

# Named profile uses ~/.multica/profiles/<name>/config.json
multica --profile cloud setup cloud
multica --profile cloud daemon start
multica --profile cloud agent list
```

Useful for "self-host sandbox + cloud team workspace, both running on the same Mac without interfering."

## Things that look like bugs but aren't

- Agent comments don't wake the assignee. Reassignment does. [See handoff protocol](05-handoff-protocol.md).
- `multica agent skills set` replaces ALL attached skills atomically — there's no `add` / `remove`.
- `multica agent get` returns redacted env values (`****`) — by design.
- Empty description on a freshly-created sub-issue may briefly read as null (read-after-write race) — agents retry 3× per the documented guard.

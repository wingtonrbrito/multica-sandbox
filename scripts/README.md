# Scripts

Tools I wrote while debugging Multica chains. All single-file, dependency-light (Python stdlib + `multica` CLI + `jq`).

## `multica-trace-issue.py` — chain timeline renderer

Renders an issue and all its descendants as a chronological timeline of every event: issue creation, status flips, comments, run lifecycle (queued/dispatched/started/completed). One view of the whole chain.

### Usage

```bash
# Live against your local self-host
./scripts/multica-trace-issue.py <issue-id>

# Live against a different profile (e.g., a cloud workspace)
./scripts/multica-trace-issue.py <issue-id> --profile cloud

# Offline from a previously-pulled snapshot directory
./scripts/multica-trace-issue.py <issue-id> --snapshot path/to/snapshot/
```

### Sample output

```
Phase trace — root issue 75fafc9c
Chain size: 3 issues

  PARENT             [75fafc9c] Add GET /api/hello endpoint — done
  qa-review          [ff13e2db] [qa-review] Review PR for ...   — done
  engineer           [e1a5f115] [engineer] Add GET /api/hello   — done

==================================================================================================
time            issue              kind     detail
==================================================================================================
04-27 19:28:27  PARENT             ISSUE    CREATED — Add GET /api/hello endpoint
04-27 19:28:29  PARENT             RUN      DISPATCH agent=orchestrator
04-27 19:29:13  engineer           ISSUE    CREATED — [engineer] Add GET /api/hello endpoint
04-27 19:30:42  engineer           COMMENT  by=engineer(agent): Created `app/api/hello/route.ts`...
04-27 19:32:25  engineer           RUN      FINISH   agent=orchestrator status=completed
...
```

## `multica-watch.sh` — live event watcher

Polls the workspace every 5s and prints one line per new event: issue creation, status changes, reassignments, comments, run lifecycle. Run it in a side terminal while firing test issues.

### Usage

```bash
# Watch self-host (default profile)
./scripts/multica-watch.sh

# Watch a different profile
./scripts/multica-watch.sh --profile cloud
```

### Sample output

```
==> multica-watch: profile=self-host, poll=5s
==> Ctrl-C to stop

13:28:03  seeded 18 issues — now watching
13:28:30  ISSUE+   [75fafc9c] Add GET /api/hello endpoint  → orchestrator (todo)
13:28:53  STATUS   [75fafc9c] Add GET /api/hello endpoint  todo → in_progress
13:29:15  ISSUE+   [e1a5f115] [engineer] Add GET /api/hello endpoint  → - (todo) parent=75fafc9c
13:29:21  REASSIGN [e1a5f115] [engineer] Add GET /api/hello endpoint  - → engineer
13:29:21  RUN      [e1a5f115] agent=engineer QUEUED
...
```

## Why these instead of the UI?

The UI is great for human inspection. The scripts are great for:

- **Repeatable runs** — pipe into a file, diff against a previous run
- **Debug at scale** — when you have 50 chains running, you can't tab through the UI
- **Headless reproduction** — chain timelines render the same offline from a snapshot as they do live
- **Scriptable assertions** — grep the watcher output to detect `STATUS .* → done` for end-to-end success

## Extending

Both are small (~250 lines each) and pure standard library. Fork freely.

Things you might want to add:
- **Slack webhook** — pipe `multica-watch` output through a filter that posts to a channel
- **Prometheus exporter** — convert events to metrics (chain duration, REVISE-loop count, ESCALATE rate)
- **Diff mode** — diff two timelines to show what changed run-over-run
- **Replay** — feed a snapshot into a script that simulates the chain client-side

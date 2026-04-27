#!/usr/bin/env bash
# multica-watch.sh — tail workspace events as they happen.
#
# Usage:
#   scripts/multica-watch.sh                 # self-host (default profile)
#   scripts/multica-watch.sh --profile cloud # David's DD-Demo
#
# Polls every 5 seconds. Prints one line per new:
#   - issue created
#   - issue status change
#   - issue reassignment
#   - issue comment added
#   - run lifecycle (queued / dispatched / started / completed)
# Seeds state from the current snapshot so only post-launch events print.
# Ctrl-C to stop.

set -u

PROFILE_ARG=()
LABEL="self-host"
if [[ "${1:-}" == "--profile" && -n "${2:-}" ]]; then
  PROFILE_ARG=(--profile "$2")
  LABEL="$2"
  shift 2
fi

POLL_INTERVAL="${POLL_INTERVAL:-5}"
STATE_DIR="${TMPDIR:-/tmp}/multica-watch-$$"
mkdir -p "$STATE_DIR"
trap 'rm -rf "$STATE_DIR"' EXIT

AGENTS_FILE="$STATE_DIR/agents.json"
ISSUES_PREV="$STATE_DIR/issues.prev.json"
ISSUES_NOW="$STATE_DIR/issues.now.json"
COMMENTS_DIR="$STATE_DIR/comments"
RUNS_DIR="$STATE_DIR/runs"
mkdir -p "$COMMENTS_DIR" "$RUNS_DIR"

echo "==> multica-watch: profile=$LABEL, poll=${POLL_INTERVAL}s"
echo "==> Ctrl-C to stop"
echo ""

# One-time agent table
multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} agent list --output json > "$AGENTS_FILE" 2>/dev/null || echo "[]" > "$AGENTS_FILE"

agent_name() {
  local id="$1"
  [[ -z "$id" || "$id" == "null" ]] && { echo "-"; return; }
  jq -r --arg id "$id" '.[] | select(.id==$id) | .name' "$AGENTS_FILE" | head -1 | {
    read name
    [[ -n "$name" ]] && echo "$name" || echo "${id:0:8}"
  }
}

short() { echo "${1:0:8}"; }

ts() { date +"%H:%M:%S"; }

emit() {
  printf "%s  %s\n" "$(ts)" "$*"
}

# Seed
multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} issue list --limit 500 --output json > "$ISSUES_PREV" 2>/dev/null
jq -r '(.issues // .)[] | .id' "$ISSUES_PREV" | while read iid; do
  multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} issue comment list "$iid" --output json > "$COMMENTS_DIR/$iid.json" 2>/dev/null
  multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} issue runs         "$iid" --output json > "$RUNS_DIR/$iid.json"     2>/dev/null
done
emit "seeded $(jq -r '(.issues // .) | length' "$ISSUES_PREV") issues — now watching"
echo ""

while true; do
  sleep "$POLL_INTERVAL"
  multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} issue list --limit 500 --output json > "$ISSUES_NOW" 2>/dev/null || continue

  # NEW issues
  jq -r --slurpfile prev "$ISSUES_PREV" '
    ($prev[0].issues // $prev[0]) as $p
    | ($p | map(.id) | sort) as $prev_ids
    | (.issues // .) as $now
    | $now[] | select((.id | IN($prev_ids[]) | not))
    | "\(.id)\t\(.title)\t\(.assignee_id // "-")\t\(.status)\t\(.parent_issue_id // "-")"
  ' "$ISSUES_NOW" | while IFS=$'\t' read iid title assignee status parent; do
    aname=$(agent_name "$assignee")
    [[ "$parent" != "-" ]] && parent_tag=" parent=$(short "$parent")" || parent_tag=""
    emit "ISSUE+   [$(short "$iid")] ${title}  → $aname ($status)$parent_tag"
    multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} issue comment list "$iid" --output json > "$COMMENTS_DIR/$iid.json" 2>/dev/null
    multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} issue runs         "$iid" --output json > "$RUNS_DIR/$iid.json"     2>/dev/null
  done

  # CHANGED issues (status / assignee flip)
  jq -r --slurpfile prev "$ISSUES_PREV" '
    ($prev[0].issues // $prev[0]) as $p
    | ($p | INDEX(.id)) as $byid
    | (.issues // .)[]
    | . as $n
    | $byid[$n.id] as $o
    | select($o != null)
    | select($o.status != $n.status or $o.assignee_id != $n.assignee_id)
    | "\(.id)\t\(.title)\t\($o.status)\t\($n.status)\t\($o.assignee_id // "-")\t\($n.assignee_id // "-")"
  ' "$ISSUES_NOW" | while IFS=$'\t' read iid title ostatus nstatus oassignee nassignee; do
    if [[ "$ostatus" != "$nstatus" ]]; then
      emit "STATUS   [$(short "$iid")] ${title}  ${ostatus} → ${nstatus}"
    fi
    if [[ "$oassignee" != "$nassignee" ]]; then
      oa=$(agent_name "$oassignee"); na=$(agent_name "$nassignee")
      emit "REASSIGN [$(short "$iid")] ${title}  ${oa} → ${na}"
    fi
  done

  # NEW comments per issue
  for iid in $(jq -r '(.issues // .)[] | .id' "$ISSUES_NOW"); do
    prev_file="$COMMENTS_DIR/$iid.json"
    now=$(multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} issue comment list "$iid" --output json 2>/dev/null)
    [[ -z "$now" ]] && continue
    if [[ -f "$prev_file" ]]; then
      prev_ids=$(jq -r 'map(.id) | sort | join(",")' "$prev_file" 2>/dev/null)
      new_ids=$(echo "$now" | jq -r 'map(.id) | sort | join(",")')
      [[ "$prev_ids" == "$new_ids" ]] && continue
      # Diff
      echo "$now" | jq --slurpfile prev "$prev_file" -r '
        ($prev[0] | map(.id)) as $p
        | .[] | select((.id | IN($p[]) | not))
        | "\(.author_id // "-")\t\(.author_type // "-")\t\((.content // "")[0:120] | gsub("\n"; " ⏎ "))"
      ' | while IFS=$'\t' read author_id author_type preview; do
        who=$(agent_name "$author_id")
        emit "COMMENT+ [$(short "$iid")] by=$who($author_type): $preview"
      done
    fi
    echo "$now" > "$prev_file"
  done

  # Run lifecycle events per issue
  for iid in $(jq -r '(.issues // .)[] | .id' "$ISSUES_NOW"); do
    prev_file="$RUNS_DIR/$iid.json"
    now=$(multica ${PROFILE_ARG[@]+"${PROFILE_ARG[@]}"} issue runs "$iid" --output json 2>/dev/null)
    [[ -z "$now" ]] && continue
    if [[ -f "$prev_file" ]]; then
      # Compare by (run_id + timestamp-field-set) — detect lifecycle advances
      echo "$now" | jq --slurpfile prev "$prev_file" -r '
        ($prev[0] | INDEX(.id)) as $old
        | .[] | . as $n
        | [
            (if ($old[.id].created_at    // "") == (.created_at    // "") then empty else "QUEUED"    end),
            (if ($old[.id].dispatched_at // "") == (.dispatched_at // "") then empty else "DISPATCH"  end),
            (if ($old[.id].started_at    // "") == (.started_at    // "") then empty else "START"     end),
            (if ($old[.id].completed_at  // "") == (.completed_at  // "") then empty else "FINISH:" + (.status // "?")  end)
          ] as $transitions
        | select($transitions | length > 0)
        | "\(.id)\t\(.agent_id // "-")\t\($transitions | join(","))"
      ' | while IFS=$'\t' read run_id agent_id transitions; do
        who=$(agent_name "$agent_id")
        emit "RUN      [$(short "$iid")] agent=$who ${transitions}"
      done
    fi
    echo "$now" > "$prev_file"
  done

  mv "$ISSUES_NOW" "$ISSUES_PREV"
done

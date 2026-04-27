#!/usr/bin/env python3
"""
Render one Multica issue (and all its descendants) as a linear timeline
of events — creation, comments, run lifecycle, reassignments.

Usage:
    multica-trace-issue.py <issue-id> [--profile cloud] [--snapshot DIR]

Pulls live from the Multica API by default. Pass --snapshot DIR to read
from a previously-pulled snapshot directory instead (offline replay).

Snapshot layout expected (see docs/multica/david-snapshot/<date>/):
    <snapshot>/issues.json                  (envelope or array with all issues)
    <snapshot>/issues/<id>.json             (per-issue detail)
    <snapshot>/issues/<id>.comments.json    (optional)
    <snapshot>/issues/<id>.runs.json        (optional)
    <snapshot>/agents.json                  (for id→name lookups)
    <snapshot>/skills.json                  (for id→name lookups)
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def run_cli(args, profile=None):
    cmd = ["multica"]
    if profile:
        cmd += ["--profile", profile]
    cmd += args + ["--output", "json"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        print(f"[warn] {' '.join(cmd)} failed: {out.stderr.strip()}", file=sys.stderr)
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def load_from_snapshot(snapshot_dir, root_id):
    """Load everything needed to trace <root_id> from a snapshot directory."""
    snap = Path(snapshot_dir)

    # Top-level issue listing (envelope or array)
    with open(snap / "issues.json") as f:
        issues_doc = json.load(f)
    issues = issues_doc["issues"] if isinstance(issues_doc, dict) else issues_doc
    by_id = {i["id"]: i for i in issues}

    # Walk tree from root
    chain_ids = [root_id]
    idx = 0
    while idx < len(chain_ids):
        parent = chain_ids[idx]
        idx += 1
        for i in issues:
            if i.get("parent_issue_id") == parent and i["id"] not in chain_ids:
                chain_ids.append(i["id"])

    # Per-issue detail (fallback to list entry if no detail file)
    details = {}
    for iid in chain_ids:
        dpath = snap / "issues" / f"{iid}.json"
        if dpath.exists():
            details[iid] = json.loads(dpath.read_text())
        else:
            details[iid] = by_id.get(iid, {"id": iid})

    # Comments + runs
    comments = {}
    runs = {}
    for iid in chain_ids:
        cpath = snap / "issues" / f"{iid}.comments.json"
        rpath = snap / "issues" / f"{iid}.runs.json"
        # Also try the alt trace dir shape: <snapshot>/trace-*/{id}.comments.json
        if not cpath.exists():
            for candidate in snap.glob(f"trace-*/{iid}.comments.json"):
                cpath = candidate
                break
        if not rpath.exists():
            for candidate in snap.glob(f"trace-*/{iid}.runs.json"):
                rpath = candidate
                break
        comments[iid] = json.loads(cpath.read_text()) if cpath.exists() else []
        runs[iid] = json.loads(rpath.read_text()) if rpath.exists() else []

    # Agents + skills for id→name
    agents = {}
    if (snap / "agents.json").exists():
        for a in json.loads((snap / "agents.json").read_text()):
            agents[a["id"]] = a.get("name") or a.get("title") or a["id"][:8]

    return chain_ids, details, comments, runs, agents


def load_live(profile, root_id):
    """Pull live from the API, walking the tree."""
    # Need full workspace issue list to find children
    issues_doc = run_cli(["issue", "list", "--limit", "500"], profile=profile)
    issues = issues_doc["issues"] if isinstance(issues_doc, dict) else issues_doc
    by_id = {i["id"]: i for i in issues}

    # Walk tree from root
    chain_ids = [root_id]
    idx = 0
    while idx < len(chain_ids):
        parent = chain_ids[idx]
        idx += 1
        for i in issues:
            if i.get("parent_issue_id") == parent and i["id"] not in chain_ids:
                chain_ids.append(i["id"])

    details, comments, runs = {}, {}, {}
    for iid in chain_ids:
        details[iid] = run_cli(["issue", "get", iid], profile=profile) or by_id.get(iid, {"id": iid})
        comments[iid] = run_cli(["issue", "comment", "list", iid], profile=profile) or []
        runs[iid] = run_cli(["issue", "runs", iid], profile=profile) or []

    agents_list = run_cli(["agent", "list"], profile=profile) or []
    agents = {a["id"]: a.get("name") or a["id"][:8] for a in agents_list}

    return chain_ids, details, comments, runs, agents


def ts(s):
    """Parse ISO8601 timestamp; None-safe."""
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def fmt_ts(s):
    dt = ts(s)
    if not dt:
        return "            "
    return dt.strftime("%m-%d %H:%M:%S")


def short_id(iid):
    return iid[:8] if iid else "--------"


def build_events(chain_ids, details, comments, runs, agents):
    """Collect all events across all issues, tagged with issue, ready to sort."""
    events = []
    for iid in chain_ids:
        d = details[iid]
        title = d.get("title", "?")

        if d.get("created_at"):
            events.append((d["created_at"], iid, "ISSUE", f"CREATED — {title}", d))

        # Last update as proxy for status transitions (Multica doesn't expose transitions directly)
        if d.get("status") in {"done", "cancelled"} and d.get("updated_at"):
            events.append((d["updated_at"], iid, "ISSUE", f"STATUS → {d['status']}", d))

        for r in runs[iid]:
            agent_name = agents.get(r.get("agent_id"), short_id(r.get("agent_id")))
            runtime = short_id(r.get("runtime_id"))
            if r.get("created_at"):
                events.append((r["created_at"], iid, "RUN", f"QUEUED   agent={agent_name} runtime={runtime} attempt={r.get('attempt','?')}", r))
            if r.get("dispatched_at"):
                events.append((r["dispatched_at"], iid, "RUN", f"DISPATCH agent={agent_name}", r))
            if r.get("started_at"):
                events.append((r["started_at"], iid, "RUN", f"START    agent={agent_name}", r))
            if r.get("completed_at"):
                status = r.get("status", "?")
                err = f" err={r.get('error')[:80]}" if r.get("error") else ""
                events.append((r["completed_at"], iid, "RUN", f"FINISH   agent={agent_name} status={status}{err}", r))

        for c in comments[iid]:
            author_kind = c.get("author_type", "?")
            author_id = c.get("author_id")
            author_name = agents.get(author_id, short_id(author_id))
            body = (c.get("content") or "").strip()
            preview = body.replace("\n", " ⏎ ")
            if len(preview) > 120:
                preview = preview[:117] + "..."
            events.append(
                (c["created_at"], iid, "COMMENT", f"by={author_name}({author_kind}): {preview}", c)
            )

    events.sort(key=lambda e: e[0])
    return events


def render(root_id, chain_ids, details, events):
    # Map issue_id → short label for left-column tag
    labels = {}
    labels[root_id] = "PARENT"
    for i, iid in enumerate(chain_ids):
        if iid == root_id:
            continue
        title = details[iid].get("title", "")
        # Extract role tag from [role] title prefix if present
        if title.startswith("["):
            role = title.split("]", 1)[0][1:]
        else:
            role = title.split(" ")[0][:14]
        labels[iid] = role

    print(f"Phase trace — root issue {root_id}")
    print(f"Chain size: {len(chain_ids)} issues")
    print()

    for iid in chain_ids:
        d = details[iid]
        print(f"  {labels[iid]:<18} [{short_id(iid)}] {d.get('title','?')} — {d.get('status','?')}")
    print()
    print("=" * 110)
    print(f"{'time':<15} {'issue':<18} {'kind':<8} detail")
    print("=" * 110)

    for ev in events:
        tstr, iid, kind, detail, _ = ev
        print(f"{fmt_ts(tstr):<15} {labels[iid]:<18} {kind:<8} {detail}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("issue_id", help="Root issue ID to trace (includes descendants)")
    p.add_argument("--profile", default=None, help="Multica profile (e.g. cloud)")
    p.add_argument("--snapshot", default=None, help="Read from snapshot dir instead of live API")
    args = p.parse_args()

    if args.snapshot:
        chain_ids, details, comments, runs, agents = load_from_snapshot(args.snapshot, args.issue_id)
    else:
        chain_ids, details, comments, runs, agents = load_live(args.profile, args.issue_id)

    events = build_events(chain_ids, details, comments, runs, agents)
    render(args.issue_id, chain_ids, details, events)


if __name__ == "__main__":
    main()

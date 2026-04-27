# 08 — Upstream Issues / PR Candidates

Bugs and small enhancements I'm proposing back to upstream [multica-ai/multica](https://github.com/multica-ai/multica). Each one has a concrete diff sketch and difficulty estimate from reading the source.

**Conventions used:** conventional commits (`feat(scope)`, `fix(scope)`), atomic commits, no special signing per upstream `CONTRIBUTING.md`.

## Gap 1 — `multica agent create` / `update` lacks `--custom-env` flag

**Severity:** medium (workflow blocker for snapshot-based cloning)

**Symptom:** `multica agent create --custom-env '{"KEY":"value"}'` returns "unknown flag." The `custom_env` field exists on the agent record and is settable via API or UI Environment tab, but there's no CLI surface.

**Why it matters:** any "clone agents from a JSON snapshot" workflow can't fully reproduce env config without manual UI clicks per agent. Breaks IaC and reproducibility patterns.

**Files:**
- `server/cmd/multica/cmd_agent.go` — add flag at lines 111–121 (create) and 123–134 (update); add parse block in handlers at ~369 (create) and ~438 (update)

**Diff sketch:**
```go
// init() in both create and update sections:
agentCreateCmd.Flags().String("custom-env", "",
    "Custom environment variables as JSON object (e.g. {\"KEY\":\"value\"})")
agentUpdateCmd.Flags().String("custom-env", "",
    "New custom environment variables as JSON object")

// In runAgentCreate() / runAgentUpdate():
if cmd.Flags().Changed("custom-env") {
    v, _ := cmd.Flags().GetString("custom-env")
    var ce map[string]string
    if err := json.Unmarshal([]byte(v), &ce); err != nil {
        return fmt.Errorf("--custom-env must be valid JSON object: %w", err)
    }
    body["custom_env"] = ce
}
```

**Tests:** `server/cmd/multica/cmd_agent_test.go` — add cases for valid JSON parse, invalid JSON error, body includes `custom_env`.

**Open design question:** merge-with-existing or replace? Current `--custom-args` replaces; recommend same for consistency.

**Difficulty:** Easy (~20 lines)

**Commit:** `feat(cli): add --custom-env flag to agent create/update`

---

## Gap 2 — `multica issue status <id> <status>` is positional-only

**Severity:** low (UX friction; not a workflow blocker)

**Symptom:** every other CLI command uses `--to` or `--status` flags, but `issue status` requires positional args. Easy to misuse: `multica issue status <id> --to cancelled` returns "unknown flag" instead of just working.

**Files:**
- `server/cmd/multica/cmd_issue.go` — command def at lines 56–61 (`Args: exactArgs(2)`), flag init at line 203, handler at lines 591–627

**Diff sketch:**
```go
// Line 57 — document both forms:
Use: "status <id> [<status>]"

// Line 59 — relax args:
Args: cobra.RangeArgs(1, 2)

// Line 203 — add flag:
issueStatusCmd.Flags().String("to", "",
    "New status (alternative to positional argument)")

// runIssueStatus() at line 591:
id := args[0]
var status string
if len(args) > 1 {
    status = args[1]
} else {
    status, _ = cmd.Flags().GetString("to")
}
if status == "" {
    return fmt.Errorf("status required: pass as positional or --to")
}
```

**Tests:** `cmd_issue_test.go` — both forms work, error when both missing, positional takes precedence if both provided.

**Difficulty:** Easy (~15 lines), fully backward compatible

**Commit:** `fix(cli): add --to flag to issue status (preserve positional form)`

---

## Gap 3 — `multica daemon status` doesn't surface backend connectivity

**Severity:** medium-high (silent failure mode)

**Symptom:** when the Docker backend goes down, the daemon process keeps running but can't poll for assignments. `multica daemon status` happily reports "running" with no indication of broken connectivity. Issues sit in `todo` forever.

**Files:**
- `server/internal/daemon/health.go` lines 16–33 (`HealthResponse` struct), 57–90 (`healthHandler`)
- `server/cmd/multica/cmd_daemon.go` lines 469–505 (`runDaemonStatus`), 522–542 (`checkDaemonHealthOnPort`)

**Diff sketch:**
```go
// 1. Extend HealthResponse struct:
type HealthResponse struct {
    // ... existing fields ...
    BackendConnectivity string `json:"backend_connectivity,omitempty"` // connected|unreachable|unknown
}

// 2. In healthHandler() — test connectivity with 2s timeout:
backendStatus := "unknown"
ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
defer cancel()
if _, err := d.apiClient.GetJSON(ctx, "/api/health", nil); err == nil {
    backendStatus = "connected"
} else {
    backendStatus = "unreachable"
}
resp.BackendConnectivity = backendStatus

// 3. Surface in CLI (cmd_daemon.go after line 500):
if conn, ok := health["backend_connectivity"].(string); ok && conn != "unknown" {
    fmt.Fprintf(os.Stdout, "Backend:     %s\n", conn)
}
```

**Open design questions:**
- Cache strategy? Synchronous 2s timeout is safer; pollLoop cache may hide transient failures.
- What counts as "connected"? Proposal: 200 OK on `/api/health` of the configured `ServerURL`.
- Should daemon log unreachable transitions? (Probably yes — we want a discoverable signal.)

**Difficulty:** Medium (~30 lines), needs `d.apiClient` accessible from `healthHandler` (may need plumbing through daemon struct)

**Commit:** `feat(daemon): surface backend connectivity in daemon status`

---

## Submission plan

| # | Gap | Difficulty | Lines | Risk | Order |
|---|---|---|---|---|---|
| 2 | `--to` on issue status | Easy | ~15 | Very low | First |
| 1 | `--custom-env` on agent create/update | Easy | ~20 | Low | Second |
| 3 | Backend connectivity in daemon status | Medium | ~30 | Medium | Third |

PRs should be independent and small. Each should land cleanly with passing CI before opening the next.

## Other potential improvements (not yet PRs)

These are observations from running the platform; haven't fully scoped them as PR candidates:

- **`agent skills` add/remove subcommands** — currently only `list` + `set` (atomic). Adding `add <skill-id>` and `remove <skill-id>` would simplify scripting. Tradeoff: complicates the API surface with redundant verbs that all reduce to `set` server-side.
- **Daemon health via systemd / launchd integration** — daemon could optionally register as a launch agent for auto-restart. Out of scope for a small PR; better as a follow-up issue.
- **`multica chain trace <issue-id>`** — first-class chain tracing in the CLI (replaces my `multica-trace-issue.py` script). Would need tree-walking + event aggregation logic; sizable PR.
- **Webhooks for chain transitions** — fire a webhook on DISPATCH/ADVANCE/REVISE/CLOSE/ESCALATE so external observers can react. Architectural addition, not a small fix.

Will revisit after the three small PRs land.

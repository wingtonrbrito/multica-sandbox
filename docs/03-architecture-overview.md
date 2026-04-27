# 03 — Architecture Overview

Multica's concepts in plain English. Read this once before reading anything else here.

## TL;DR

Multica is **Linear (issue tracker) + AI agents you can assign issues to**. Agents are spawned as subprocesses by a local daemon when an issue lands in their queue. They read the issue, do work, comment back, hand off via reassignment.

That's the whole product.

## The core concepts

| Concept | What it is |
|---|---|
| **Workspace** | The container. Like a "company." Everything below lives inside one workspace. |
| **Member** | A human user with an account. |
| **Agent** | An AI "employee" — has a name, instructions, attached skills, a runtime, and a model. Can be the assignee on an issue. |
| **Skill** | A reusable markdown procedure document. **Workspace-scoped, not per-agent.** Agents reference them by attachment. |
| **Issue** | A work ticket. Title, description, status, assignee. Assignment-driven: assigning an issue to an agent wakes it. |
| **Runtime** | A registered local agent CLI (`claude`, `codex`, `gemini`, etc.) on a specific machine. |
| **Daemon** | A long-running process that polls the workspace server and spawns the right runtime when work arrives. |
| **Autopilot** | A scheduled trigger that creates issues on a cron-like cadence. |
| **Project** | A grouping of issues for organizational purposes. Optional. |

## How a chain runs (the choreography)

Say you create an issue "Add a /hello endpoint" and assign it to your `orchestrator` agent.

```
1. Daemon polls the server every 3s. Server says "orchestrator has a new issue."
2. Daemon creates an isolated workspace dir (~/multica_workspaces/<ws>/<task>/).
3. Daemon spawns Claude Code (or Codex, etc.) as a subprocess in that dir.
4. Daemon injects a prompt: "Your assigned issue ID is X. Run `multica issue get X --output json` first."
5. Agent reads the issue. Decides what to do based on its Instructions + attached Skills.
6. Agent acts: creates sub-issues, posts comments, reassigns issues.
7. Agent exits when its work is done. Process is gone — no memory.
8. If a reassignment happened, the next assignee's daemon picks up the work and the cycle repeats.
9. When orchestrator decides the chain is complete, it closes the parent issue.
```

**Two load-bearing rules:**

1. **Assignment wakes. Agent comments don't.** The wake signal is exclusively a change in `assignee_id`. To pass the baton, reassign — don't just comment.
2. **Every wake is stateless.** The agent fetches its issue every time and decides what state it's in. No memory of prior wakes. This is what makes the system simple to reason about (and crash-safe).

## What each agent tab in the UI controls

Click any agent in the UI. The right pane shows tabs:

| Tab | Maps to | Notes |
|---|---|---|
| **Instructions** | `agent.instructions` | The system prompt. First thing the agent reads on every wake. |
| **Skills** | `agent.skills` (a set of skill IDs) | Which library skills this agent has been "trained on." Doesn't *contain* skill content — references it. |
| **Tasks** | `multica issue list --assignee <agent>` | The agent's work history. |
| **Environment** | `agent.custom_env` + `agent.custom_args` | Env vars + CLI flags passed to the runtime subprocess. **This is where tool restrictions, MCP configs, and secrets live.** |

Other tabs may exist (Runtime selector, Model, etc.) — they all just shape the subprocess invocation.

## The two "Skills" places (don't get confused)

- **Sidebar → Configure → Skills** — the workspace **library**. Skill content lives here.
- **Agent page → Skills tab** — the agent's **library card**. Lists which library skills are attached.

These are two views of the same underlying resource. Editing skill content in one place updates the other. **There is no per-agent skill ownership** — it's all workspace-level.

This shape has consequences:
- Modifying a skill changes it for every agent that references it
- Detaching a skill from an agent (`agent skills set`) doesn't delete it from the library
- `skill delete` removes from library; behavior toward currently-attached agents depends on Multica version (test before relying on it)
- "Private to one agent" isn't enforceable at the platform level — only by naming convention

## Tool authorization

Each agent's `custom_args` typically includes `--allowedTools <list>`. The list controls which tools (Bash, Read, Edit, mcp__github__*, etc.) the agent's runtime is allowed to invoke.

This is how you implement **role-level guardrails**: a read-only analyst agent gets `--allowedTools Bash Read Glob Grep`. An engineer gets `Bash Read Write Edit`. A reviewer gets nothing destructive.

`--allowedTools` is enforced by the runtime CLI (Claude Code, Codex, etc.), not by Multica itself. Don't rely on it for security against a malicious agent prompt — it's a guardrail, not a sandbox.

## Where the secrets live

Per-agent secrets (API tokens, etc.) can go two places:

1. **`agent.custom_env`** — encrypted on the Multica server, injected into the subprocess at dispatch time. Edit via UI's Environment tab. Portable across runtimes.
2. **An MCP config file on the runtime's disk** — referenced via `--mcp-config <path>` in `custom_args`. Multica never sees what's inside.

Pick (1) for portability, (2) for "secrets never leave my machine" + git-trackable config.

## Wake model — why it's stateless

When an agent wakes, it has access to:
- Its assigned issue ID (injected by the daemon as a prompt prefix)
- The full Multica workspace state (via the CLI)
- Whatever its tools can read

It does NOT have:
- Memory of what it did last wake
- A persistent in-memory store
- Access to other agents' processes

This is deliberate. Statelessness means:
- Agents can be restarted at any point with no harm
- Wakes can be triggered out of order without breaking
- A crashed agent's next wake just re-decides from current state
- Idempotency falls out of the design — same input → same decision

The cost: every wake re-reads everything. For small workspaces this is fine. At scale, it's a known tradeoff.

## What's NOT in Multica (but you'll wish were)

- **Workspace-level tool authorization** (every `--allowedTools` is per-agent)
- **Per-agent private skill libraries** (skills are workspace-only)
- **CLI-settable `custom_env`** (UI only at present)
- **Built-in approval gates** (you have to script them yourself)
- **Cross-workspace agent sharing** (each workspace is an island)
- **Runtime sandboxing** (your agent runs as your user, with your filesystem access)

## Mental model in one sentence

> Multica is Linear, except the assignees can be AI subprocesses your local daemon spawns — wired together by reassignment-as-wake-signal and a stateless decision loop on every wake.

# Fork Strategy

How our two forks relate to upstream, where each branch lives, and how others (David, anyone else, future projects of yours) consume them.

We maintain forks of two repos, both following the same `main` + `feat/*` + `wingtonrbrito-customizations` pattern:

- [`wingtonrbrito/multica`](https://github.com/wingtonrbrito/multica) — fork of `multica-ai/multica` (the AI-native task platform)
- [`wingtonrbrito/huly-mcp-server`](https://github.com/wingtonrbrito/huly-mcp-server) — fork of `kwhittenberger/huly-mcp-server` (the Huly MCP server we use for Multica's `huly-scan` / `huly-writeback` skills)

The TL;DR for both: **clone, check out `wingtonrbrito-customizations`, and you have a working build with all our open-PR patches included.**

---

## Multica fork

### The shape

```
multica-ai/multica                (upstream — the official Multica repo)
        │
        │ fork
        ▼
wingtonrbrito/multica             (our fork)
        │
        ├── main                              ← tracks upstream/main exactly
        ├── fix/cli-issue-status-to-flag      ← branch backing PR #1805
        ├── feat/daemon-backend-connectivity  ← branch backing PR #1910
        └── wingtonrbrito-customizations      ← long-lived local-patches branch
```

The canonical doc on this branch structure (and what's expected to land where) lives on the fork itself at [`CUSTOMIZATIONS.md`](https://github.com/wingtonrbrito/multica/blob/wingtonrbrito-customizations/CUSTOMIZATIONS.md).

---

## What goes where

### `main`
- Tracks `upstream/main` exactly. No local mods.
- Sync weekly: `git fetch upstream main && git merge upstream/main`.
- Use this branch when you want stock upstream behavior or are about to start a new upstream PR.

### `feat/...` and `fix/...` branches
- Short-lived branches for upstream PRs.
- Each one targets `multica-ai/multica:main` via PR.
- Once merged upstream, the branch is deleted.

### `wingtonrbrito-customizations`
- Long-lived. Holds patches that aren't (yet) destined for upstream.
- Periodically rebased onto fresh `main` to absorb upstream changes.
- This is the branch you check out if you want "stock Multica + our local patches."

---

## Recipes for consuming our fork

### Want everything (stock + customizations)
```bash
git clone https://github.com/wingtonrbrito/multica
cd multica
git checkout wingtonrbrito-customizations
```

### Want only the upstream patches we've contributed
- Once merged upstream, they're in `multica-ai/multica`'s main. Pull from there.
- Pre-merge (still under review): `git fetch wingtonrbrito-multica fix/cli-issue-status-to-flag` and check it out as a local branch.

### Want one specific commit from our customizations
```bash
git remote add wingtonrbrito-multica https://github.com/wingtonrbrito/multica
git fetch wingtonrbrito-multica wingtonrbrito-customizations
git cherry-pick <sha>
```

### Want to fork our fork (your own customizations on top)
```bash
gh repo fork wingtonrbrito/multica
# you now have <your-handle>/multica with all branches mirrored
```

### Multi-project reuse
If you're using Multica in multiple projects:
- Each project's deployment / CI references our fork by URL
- Each project picks a branch:
  - `main` for stock upstream behavior with fast updates
  - `wingtonrbrito-customizations` for our local patches included
  - A specific tag for stability-pinned deployments
- When you want updates, `git pull` (or rebuild the deployment artifact)

---

## Sync cadence (how to keep the fork current)

```bash
cd /path/to/wingtonrbrito/multica

# Pull in upstream changes
git checkout main
git fetch upstream main
git merge upstream/main          # or rebase if you prefer linear history
git push origin main

# Bring those upstream changes into the customizations branch
git checkout wingtonrbrito-customizations
git rebase main                   # or merge — pick a convention and stick with it
git push --force-with-lease origin wingtonrbrito-customizations
```

Suggested cadence: weekly, or before any deployment, or before opening a new upstream PR.

---

## When a customization-branch patch lands upstream

If we PR'd a patch upstream and it merged:
1. Drop the now-redundant commit from `wingtonrbrito-customizations` on the next rebase.
2. The functionality is now in upstream `main`, no local patch needed.

This keeps the customizations branch focused on patches that genuinely live only in our fork.

---

## huly-mcp-server fork

Same shape, smaller scope. The Huly MCP server is the bridge that lets Multica's `huly-scan` / `huly-writeback` skills read/write to Huly. We carry three patches against upstream `master`.

### The shape

```
kwhittenberger/huly-mcp-server          (upstream — the official MCP server)
        │
        │ fork
        ▼
wingtonrbrito/huly-mcp-server           (our fork)
        │
        ├── master                                       ← tracks upstream/master exactly
        ├── feat/node-runtime-polyfill                   ← branch backing PR #2
        ├── feat/add-comment-and-list-relations          ← branch backing PR #3
        ├── feat/update-issue-assignee                   ← branch backing PR #4
        └── wingtonrbrito-customizations                 ← all three patches merged together
```

The canonical doc lives on the fork itself at [`CUSTOMIZATIONS.md`](https://github.com/wingtonrbrito/huly-mcp-server/blob/wingtonrbrito-customizations/CUSTOMIZATIONS.md).

### What's on each branch

| Branch | Purpose |
|---|---|
| `master` | Tracks `upstream/master`. No local mods. |
| `feat/node-runtime-polyfill` | PR #2 — `launch.mjs` polyfill for Node-runtime browser globals. Adds `fake-indexeddb` dep. |
| `feat/add-comment-and-list-relations` | PR #3 — adds `add_comment` and `list_issue_relations` tools. Adds `@hcengineering/chunter` dep. |
| `feat/update-issue-assignee` | PR #4 — `update_issue(assignee="<email>")` resolves email → Employee via Channel. Adds `@hcengineering/contact` dep. |
| `wingtonrbrito-customizations` | All three above, merged together on top of fresh `master`. |

### Recipes for consuming this fork

#### Want everything (stock + all 3 open patches)
```bash
git clone https://github.com/wingtonrbrito/huly-mcp-server
cd huly-mcp-server
git checkout wingtonrbrito-customizations
npm install
node launch.mjs
```

Set the same env vars upstream documents (`HULY_URL`, `HULY_EMAIL`, `HULY_PASSWORD`, `HULY_WORKSPACE`).

#### Wire into Claude Code MCP config
```jsonc
{
  "mcpServers": {
    "huly": {
      "command": "node",
      "args": ["/absolute/path/to/huly-mcp-server/launch.mjs"],
      "env": { "HULY_URL": "...", "HULY_EMAIL": "...", "HULY_PASSWORD": "...", "HULY_WORKSPACE": "..." }
    }
  }
}
```

#### Cherry-pick just one feature
Each `feat/*` branch is one commit on top of upstream `master`. Cherry-pick the SHA you want.

### Sync cadence (huly-mcp-server)
Same as multica — when upstream `master` advances:
```bash
cd /path/to/wingtonrbrito/huly-mcp-server
git checkout master
git fetch upstream master
git merge --ff-only upstream/master
git push origin master

git checkout wingtonrbrito-customizations
git rebase master
git merge --no-ff feat/node-runtime-polyfill
git merge --no-ff feat/add-comment-and-list-relations
git merge --no-ff feat/update-issue-assignee
git push --force-with-lease origin wingtonrbrito-customizations
```

When kwhittenberger merges one of our PRs, drop that branch from the merge graph and delete it.

---

## Why this layout

- **One repo, clear branch semantics.** No need for two separate forks.
- **Upstream PRs stay clean** — each PR is its own short-lived `feat/...` or `fix/...` branch off `main`. The customizations branch never gets in the way.
- **Customizations are isolated** — anyone wanting our local patches checks out one branch.
- **Easy to consume from multiple projects** — pin to a branch or tag from the same fork.

---

## Related

- [`wingtonrbrito/multica:CUSTOMIZATIONS.md`](https://github.com/wingtonrbrito/multica/blob/wingtonrbrito-customizations/CUSTOMIZATIONS.md) — canonical source for what's currently on the multica customizations branch
- [`wingtonrbrito/huly-mcp-server:CUSTOMIZATIONS.md`](https://github.com/wingtonrbrito/huly-mcp-server/blob/wingtonrbrito-customizations/CUSTOMIZATIONS.md) — same for huly-mcp
- [`UPSTREAM-CONTRIBUTIONS.md`](../UPSTREAM-CONTRIBUTIONS.md) — live status of PRs against upstream

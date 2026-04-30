# Pattern — Codex CLI as cross-model QA + REVISE retest plan

The REVISE state machine in our orchestrator handles `qa-review` returning `needs-revision` by re-dispatching to engineer with the qa-review's `revision_notes`. Earlier validation showed Sonnet 4.6 was too capable to organically produce a needs-revision verdict on diff-verifiable specs (engineer + QA were both Sonnet, so they shared blind spots).

The cleanest validation: cross-model. Engineer = Sonnet, QA = Codex (OpenAI). They have different blind spots and reasoning styles, so QA-as-Codex more aggressively flags engineer-as-Sonnet's near-misses. This also matches David's DD-Demo topology where QA Review is configured with `gpt-5.3-codex`.

## Install

```bash
npm install -g @openai/codex
codex --version
```

Auth via OpenAI API key:

```bash
codex auth login           # browser-based OAuth flow
# OR
export OPENAI_API_KEY=sk-...
codex --help
```

Confirm the runtime is healthy:

```bash
codex run --help            # daemon-style invocation; what Multica calls
```

## Multica runtime registration

Multica needs to know about the Codex runtime so agents can be configured against it.

```bash
multica daemon stop        # daemon needs to re-scan runtimes on next start

# Add to ~/.multica/config.json under `runtimes`:
#   {
#     "name": "Codex",
#     "mode": "local",
#     "provider": "codex",
#     "binary_path": "/opt/homebrew/bin/codex"
#   }
# OR via CLI if the verb exists in the version we're on:
multica runtime add --name "Codex" --provider codex --binary-path "$(which codex)"

multica daemon start
multica runtime list       # confirm Codex appears alongside Claude and Gemini
```

Note: as of v0.2.9 the CLI's `runtime add` may not exist. If so, edit the config file directly and restart the daemon — the daemon's startup scan picks up the new runtime.

## Agent re-binding

Swap `QA Review` agent to use the Codex runtime, keep `engineer` on Claude:

```bash
QA_AGENT=$(multica agent list --output json | python3 -c "
import json,sys
agents=json.load(sys.stdin)
agents = agents if isinstance(agents, list) else agents.get('agents',[])
for a in agents:
    if a.get('name') == 'QA Review': print(a.get('id'))")
CODEX_RUNTIME=$(multica runtime list --output json | python3 -c "
import json,sys
runtimes=json.load(sys.stdin)
runtimes = runtimes if isinstance(runtimes, list) else runtimes.get('runtimes',[])
for r in runtimes:
    if r.get('provider') == 'codex': print(r.get('id'))")

multica agent update "$QA_AGENT" --runtime-id "$CODEX_RUNTIME" --model "gpt-5.3-codex"
```

## REVISE retest

File a Huly issue with a deliberately easy-to-miss-something ask:

```
Title: multica-sandbox: add /api/echo endpoint with strict input validation
Description:
  Reviewer: codingin30@gmail.com

  Add GET /api/echo?msg=<text> that returns {"echo":"<msg>"}.
  Required: 400 if msg is missing OR longer than 200 chars.
  Required: HTTP-only cache headers — Cache-Control: no-store.
  Required: input must be HTML-escaped in the response (XSS prevention).
```

Expectation: the Sonnet engineer is likely to nail GET + msg+length check but may forget the cache header AND/OR the HTML escape. Codex-as-QA flags both as `needs-revision`. Engineer redispatch fixes the gaps. Second QA pass approves. Chain CLOSEs.

If REVISE fires:
- ✅ State machine works under cross-model.
- ✅ qa-review's `revision_notes` are surfaced verbatim to Huly via huly-writeback's REVISE template.
- ✅ Engineer respects the 3-revision cap (4th attempt → ESCALATE).

If REVISE never fires across 3 separate runs:
- Either the ask is too easy for both models (refine the ask), or QA is being lenient (tighten the QA prompt).

## Cost note

Codex pricing differs from Claude. Running Sonnet engineer + Codex QA is roughly 2x the per-chain cost of pure-Claude. For demo / validation runs that's fine; for steady-state you may want a Sonnet-ensemble QA (two Sonnet QA agents in fan-out, each with a different prompt-flavor) to get the cross-prompt diversity benefit without paying for Codex.

## Status

Plan written. Not yet executed:

- Codex CLI install — needs user action (npm i -g + login).
- Runtime registration — needs daemon restart.
- Agent re-bind — one CLI call once runtime exists.
- REVISE retest — once everything's wired, file the test issue + watch.

Estimated effort: 30 min for the install + wiring; ~15 min per validation run.

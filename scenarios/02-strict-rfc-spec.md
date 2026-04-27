# Scenario 02 — Strict RFC 7231 endpoint

Same setup as [Scenario 01](01-simple-endpoint.md), but with much stricter acceptance criteria designed to test whether the engineer agent handles edge-case HTTP semantics correctly.

## The issue

```bash
multica issue create \
  --title "Add /api/hello endpoint with strict HTTP semantics" \
  --assignee orchestrator \
  --priority medium \
  --description "Add an /api/hello endpoint that strictly conforms to RFC 7231 HTTP semantics.

Target repo: /absolute/path/to/multica-sandbox
Remote: origin
Base branch: main

Required exports in app/api/hello/route.ts:
* GET — returns 200 with JSON body {\"hello\": \"world\", \"timestamp\": <ISO8601 UTC string ending in Z>}
* HEAD — explicit export (do NOT rely on Next.js auto-HEAD); returns 200 with same headers as GET, empty body
* OPTIONS — returns 204 with header Access-Control-Allow-Methods: GET, HEAD, OPTIONS
* POST, PUT, DELETE, PATCH — each must return 405 Method Not Allowed WITH the Allow header set to GET, HEAD, OPTIONS (RFC 7231 mandatory)

All non-204 responses MUST set every one of these response headers:
* Content-Type: application/json
* Vary: Accept
* Cache-Control: no-store
* X-Powered-By: multica-sandbox

Additional acceptance criteria:
* No other files modified
* Use NextResponse from next/server (not the older Response API)
* Timestamp must be generated fresh on every request (do not memoize)
* JSON serialization order: hello key first, timestamp second

Non-goals: no tests, no middleware changes, no rate-limiting."
```

## Result

**Approved on first try, FULL spec compliance.** Total chain time: 6m 35s.

Engineer's actual output: [`examples/api-hello-route.ts`](../examples/api-hello-route.ts). Note:
- `HEAD` exported explicitly
- `Allow: GET, HEAD, OPTIONS` header on all 405 responses
- `Vary: Accept` on every non-204 response
- `NextResponse` from `next/server` used (not legacy `Response`)
- JSON key order matches spec (`hello` before `timestamp`)

## What this proves

Sonnet 4.6 is capable on a strict, diff-verifiable single-file Next.js spec. The platform doesn't slow down with stricter requirements — engineer just produces more code. QA reads the diff against the criteria and gives accurate verdicts.

## What this does NOT prove

The REVISE loop. The original intent was that explicit-HEAD + Allow-header + Vary-header criteria would be hard enough to make the engineer miss something. Empirically: not hard enough.

To force a REVISE on Sonnet 4.6, see [`03-revise-loop-recipe.md`](03-revise-loop-recipe.md) (in progress).

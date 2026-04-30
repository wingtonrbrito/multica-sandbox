# RFC — Outbound webhooks on issue/run state transitions

**Status:** Draft for upstream review
**Author:** wingtonrbrito
**Filed against:** [`multica-ai/multica`](https://github.com/multica-ai/multica)
**Date:** 2026-04-30

## Problem

External systems integrating with Multica (Huly issue tracker, n8n, Slack, observability platforms, custom dashboards) need to react to chain transitions — issue created, status changed, comment posted, run completed, autopilot tick fired. Today the only options are:

1. **Poll the REST API** (`/api/issues`, `/api/issues/<id>/runs`). High latency, expensive at scale, easy to miss short-lived transitions.
2. **Subscribe to the WebSocket realtime layer** as if you were a logged-in client. Couples integrators to a frontend transport that wasn't designed for server-to-server use, and the auth model is session-cookie shaped.
3. **Run an autopilot whose trigger kind is `webhook`** (already supported per `server/internal/handler/autopilot.go:441`). But this is *inbound* — external system → Multica. The reverse direction (Multica → external) has no first-class affordance.

The internal `events.Bus` (`server/internal/events/bus.go`) already publishes typed events for every issue / run / comment transition that flows through handlers, and the realtime layer subscribes to them. **The infrastructure is in place — only the outbound HTTP sink is missing.**

## Proposal

Add a per-workspace **outbound webhook subscription** that listens on the existing `events.Bus` and POSTs each matching event to a configured URL with HMAC-SHA256 signing. Reuses the same event types the internal bus already publishes; no new event taxonomy required.

### Surface area

A new `webhook_subscriptions` table:

```sql
CREATE TABLE webhook_subscriptions (
  id            UUID PRIMARY KEY,
  workspace_id  UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  url           TEXT NOT NULL,
  secret        TEXT NOT NULL,                                    -- HMAC key, never returned by API
  event_types   TEXT[] NOT NULL,                                  -- ["issue:status_changed", "run:completed", ...]
  status        TEXT NOT NULL CHECK (status IN ('active','paused')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_delivery_at        TIMESTAMPTZ,
  last_delivery_status    INT,                                    -- HTTP status of last attempt
  consecutive_failures    INT NOT NULL DEFAULT 0
);
```

CLI surface (modeled after `multica autopilot trigger-add`):

```
multica webhook list
multica webhook create --name "huly-mirror" --url "https://huly.app/api/multica-webhook" \
                       --event-types "issue:status_changed,issue:comment_added,run:completed"
multica webhook update <id> --status paused
multica webhook delete <id>
multica webhook deliveries <id>      # last N attempts with response codes
```

REST: `POST /api/webhooks`, `GET /api/webhooks`, `PUT /api/webhooks/<id>`, `DELETE /api/webhooks/<id>`.

### Payload shape

Event payload reuses the existing `events.Event` struct, plus delivery metadata:

```json
{
  "delivery_id": "del_abc123",
  "subscription_id": "sub_def456",
  "delivered_at": "2026-04-30T22:30:00Z",
  "attempt": 1,
  "event": {
    "type": "issue:status_changed",
    "workspace_id": "05a77012-31a4-4cc1-83b5-93f7e596820c",
    "actor_type": "agent",
    "actor_id": "107f3dd6-9163-4e2f-884d-65b83ef70fb1",
    "task_id": "abc...",
    "payload": {
      "issue_id": "8b7a5ba5-...",
      "identifier": "AIP-50",
      "from_status": "in_progress",
      "to_status": "done",
      "title": "Add /api/practice-1 endpoint",
      "...": "..."
    }
  }
}
```

### Auth — HMAC-SHA256

Each delivery is signed with the subscription's secret:

```
X-Multica-Signature: sha256=<hex>
X-Multica-Delivery: del_abc123
X-Multica-Event: issue:status_changed
```

Where `<hex>` = `HMAC-SHA256(secret, raw-request-body)`. The receiver validates the signature; the secret never leaves the server in plaintext (the API returns it once at create-time, then masked thereafter — same pattern as `--custom-env` with `--custom-env-stdin` recently shipped).

### Delivery semantics

- **At-least-once** with idempotency. The `delivery_id` is unique per attempt; receivers dedupe on `(subscription_id, event.id)` (where `event.id` is added to `events.Event` for this purpose — small breaking change to the internal bus).
- **Retry policy:** exponential backoff at 1s, 5s, 30s, 5m, 30m. After 5 failures the subscription is auto-paused; admins re-enable via API.
- **Timeout:** 5s per delivery attempt (configurable).
- **Ordering:** best-effort per `workspace_id` via a single goroutine consumer. Strict ordering is not guaranteed across workspaces. (Receivers that need strict order should batch-process by `event.payload.<resource>_id`.)

### Event types — bootstrap set

Mirroring the existing internal bus events that already exist in handler code:

- `issue:created`
- `issue:updated` (catch-all for title/description/priority/assignee changes)
- `issue:status_changed` (separate from `issue:updated` because status transitions are the most-subscribed-to event)
- `issue:comment_added`
- `issue:deleted`
- `run:started`
- `run:completed`
- `run:failed`
- `autopilot:triggered`

A `*` wildcard subscribes to all current and future event types.

### What it does NOT do

- It does NOT emit batched events (one delivery per event). Batching can layer on later if needed.
- It does NOT support inbound auth challenges (no `verify` endpoint a la GitHub). Add later if integrator demand is high.
- It does NOT replace the existing autopilot `webhook` trigger kind (which is *inbound*). The two are orthogonal — inbound webhooks let external systems wake autopilots; outbound webhooks let external systems react to Multica state.

## Implementation outline

**Total surface:** ~600 LOC including tests. Estimated 1-2 days for a maintainer.

1. **Schema migration** (`server/internal/migrations/`) — `webhook_subscriptions` table.
2. **`server/internal/webhooks/sink.go`** — new package. `Sink` struct subscribes to `events.Bus.SubscribeAll`, filters by per-subscription `event_types`, queues deliveries on a per-workspace channel, and a worker pool dispatches to URLs with HMAC signing + retry. Bounded queue (e.g. 1000 events/workspace) — overflow logs and drops the oldest with a metric increment.
3. **`server/internal/handler/webhooks.go`** — REST CRUD handlers. Mirrors `autopilot.go` shape.
4. **CLI** (`server/cmd/multica/cmd_webhook.go`) — modeled after `cmd_autopilot.go`. Subcommands: `list`, `create`, `update`, `delete`, `deliveries`.
5. **Wiring** in `server/cmd/multica-server/main.go` — instantiate `webhooks.Sink`, pass it the `events.Bus` reference (already constructed), let it call `SubscribeAll`.
6. **Tests** — unit tests for HMAC signing, retry backoff, queue overflow handling. Integration test using a `httptest.Server` as the receiver, asserting at-least-once + ordering within workspace.
7. **Docs** — `WEBHOOKS.md` at repo root, examples for the bootstrap event types.

## Why this matters

The current Huly ↔ Multica integration relies on:

1. Inbound: Multica polls Huly via the huly-mcp tools on a scheduled `Huly Scan` autopilot tick.
2. Outbound: Multica posts comments + flips status on Huly via huly-writeback skill at chain transitions, called by the orchestrator agent.

(2) works but burns LLM tokens on every transition since the orchestrator agent is the entity making the writeback. An outbound webhook would let a stateless `huly-mirror` service handle writeback at zero LLM cost — the orchestrator just emits Multica state changes, and the webhook subscriber translates those into Huly comments/status flips with deterministic code. Same pattern applies to Slack, n8n, custom dashboards.

It also makes Multica composable into existing CI/CD pipelines without each integrator reinventing the polling layer.

## Alternatives considered

- **Server-Sent Events (SSE) endpoint instead of webhooks.** Lower friction for client-side subscribers but requires the integrator to host a long-lived connection. Webhooks fit the predominant integration model (one-off HTTP receivers in Cloud Run, Lambda, n8n, etc.) better.
- **Reuse the existing `Hub` realtime WebSocket layer** with a server-to-server auth mode. Adds complexity to a layer that's already optimized for browser clients; the outbound webhook path is simpler.
- **Rely on autopilot scheduled ticks for periodic polling.** Works for low-cardinality integrations but doesn't scale to per-event reactivity, and burns LLM tokens (see "Why this matters").

## Open questions for maintainers

1. Is there an existing event-id field on `events.Event`, or would adding one be a breaking-ish change? (Skim suggests no — would need `Event.ID string` added to the struct.)
2. Should the per-workspace bounded queue overflow drop oldest or block? (Prefer drop-oldest with a metric — back-pressure from a slow webhook receiver shouldn't stall Multica's reactive flow.)
3. Pause-on-N-failures policy: 5 the right default, or configurable per subscription?
4. Should the CLI's `webhook deliveries` command include the response body (truncated), or just status/timing? (Useful for debugging webhook receivers that 200 with an error in the body.)

## Filing plan

If this RFC has rough alignment, I'll file it as a GitHub issue against `multica-ai/multica`, or open a draft PR with the schema migration + scaffolding to get concrete review feedback.

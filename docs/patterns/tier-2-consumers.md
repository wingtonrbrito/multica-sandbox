# Tier 2 outbound consumer recipes

Using the outbound webhook system shipped in [PR #2295](https://github.com/multica-ai/multica/pull/2295) (implements [RFC #1964](https://github.com/multica-ai/multica/issues/1964)) to fan out Multica events to platforms that don't accept the generic HMAC-signed POST shape directly. Each recipe is a small adapter (5-30 lines) on the receiver side that translates Multica's outbound payload into the target platform's required shape.

## Tier 1 vs Tier 2 vs Tier 3 — quick refresher

**Tier 1** (zero adapter, works natively): Slack, Microsoft Teams (direct webhook URL), Discord, n8n, Zapier, Make.com, IFTTT, Mattermost, Rocket.Chat, Element/Matrix, PagerDuty, Opsgenie, Datadog, Honeycomb, Sentry, GitHub Actions (`repository_dispatch`). These accept Multica's HMAC-signed POSTs directly because they're already designed to receive generic webhook payloads.

**Tier 2** (small adapter, this doc): Twilio SMS, Email gateways (Resend / Postmark / SES), Asana, Notion, Trello, Jira Cloud, Bitbucket Cloud, Confluence, Microsoft Teams (when custom transformation is needed), Google Chat. These platforms don't accept generic HMAC-signed POSTs but offer their own auth-shaped APIs. A 5-30 line adapter translates the Multica payload into the platform's expected shape.

**Tier 3** (full bridge): legacy systems and CRMs without webhook ingestion at all. For these, route through n8n / Zapier as an intermediate that does the polling on Multica's behalf and translates to the vendor API.

This doc covers Tier 2 with copy-paste-ready recipes.

---

## The common adapter shape

Every Tier 2 adapter has the same skeleton: receive HMAC-signed POST → verify signature → extract relevant fields → call target platform's API → return appropriate status code so Multica retries (or doesn't).

### Node.js skeleton (Cloudflare Worker / Lambda / Vercel Function)

```javascript
import crypto from 'node:crypto';

// MULTICA_SECRET = the secret returned by `multica webhook create`. Set in worker env.
// TARGET_API_KEY = the receiver platform's API key.
//
// Multica retries on 5xx. Return 5xx if the target API failed; 2xx only on success.

export default {
  async fetch(request, env) {
    const rawBody = await request.text();
    const sig = request.headers.get('X-Multica-Signature') || '';

    // 1. Verify HMAC-SHA256 over the raw body.
    if (!verifyMulticaSignature(rawBody, sig, env.MULTICA_SECRET)) {
      return new Response('invalid signature', { status: 401 });
    }

    // 2. Extract the event we care about.
    const { event } = JSON.parse(rawBody);
    const { id: eventId, type: eventType, payload } = event;

    // 3. Call the target API. Throw → 5xx → Multica retries.
    try {
      await callTargetApi(eventId, eventType, payload, env);
      return new Response('ok', { status: 200 });
    } catch (err) {
      console.error('target-api failure', { eventId, eventType, error: err.message });
      return new Response(err.message, { status: 502 });
    }
  },
};

function verifyMulticaSignature(body, header, secret) {
  if (!header.startsWith('sha256=')) return false;
  const expected = crypto.createHmac('sha256', secret).update(body).digest('hex');
  const provided = header.slice(7);
  if (expected.length !== provided.length) return false;
  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(provided));
}

async function callTargetApi(eventId, eventType, payload, env) {
  // Override per-recipe.
}
```

### Python equivalent (FastAPI / Lambda)

```python
import hmac, hashlib
from fastapi import FastAPI, Request, HTTPException

app = FastAPI()

def verify_multica_signature(body: bytes, header: str, secret: str) -> bool:
    if not header.startswith("sha256="):
        return False
    expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header[7:])

@app.post("/webhook")
async def receive(request: Request):
    raw = await request.body()
    sig = request.headers.get("X-Multica-Signature", "")
    if not verify_multica_signature(raw, sig, MULTICA_SECRET):
        raise HTTPException(401, "invalid signature")
    event = (await request.json()).get("event", {})
    # call target API; raise on failure → FastAPI returns 5xx → Multica retries
    return {"ok": True}
```

Every recipe below extends one of these two skeletons by filling in `callTargetApi`.

---

## Recipe 1: Twilio SMS

**Use case:** operational alerts (chain failed, autopilot auto-paused, build failed). NOT marketing — Twilio per-SMS pricing makes that uneconomical.

**Recommended events to subscribe:**
```
multica webhook create --name twilio-sms-alerts \
  --url https://your-worker.example.workers.dev \
  --events 'task:failed,autopilot:run_done,webhook:auto_paused'
```

**Adapter (Cloudflare Worker):**

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  const body = formatSMSBody(eventType, payload);
  const auth = btoa(`${env.TWILIO_ACCOUNT_SID}:${env.TWILIO_AUTH_TOKEN}`);
  const formData = new URLSearchParams({
    From: env.TWILIO_FROM_NUMBER,    // e.g. '+15551234567'
    To: env.TWILIO_TO_NUMBER,        // your on-call phone
    Body: body,
  });

  const resp = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${env.TWILIO_ACCOUNT_SID}/Messages.json`,
    {
      method: 'POST',
      headers: {
        Authorization: `Basic ${auth}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: formData,
    },
  );
  if (!resp.ok) throw new Error(`twilio ${resp.status}: ${await resp.text()}`);
}

function formatSMSBody(eventType, payload) {
  // Keep under 160 chars when possible.
  switch (eventType) {
    case 'task:failed':
      return `[Multica] task failed: ${payload.title || payload.id}`;
    case 'autopilot:run_done':
      return `[Multica] autopilot ${payload.autopilot_id} done (${payload.status})`;
    case 'webhook:auto_paused':
      return `[Multica] webhook ${payload.name} auto-paused after ${payload.consecutive_failures} failures`;
    default:
      return `[Multica] ${eventType}: ${JSON.stringify(payload).slice(0, 100)}`;
  }
}
```

**Cost note:** Twilio outbound SMS is roughly $0.008/message in US (varies by destination). For high-volume signals (e.g. `task:queued`), use Slack or Teams instead — SMS is for the small set of events someone needs to know about even if they're away from the keyboard.

---

## Recipe 2: Email via Resend

**Use case:** human-readable reports, longer-form summaries, escalations.

**Setup:** create a Resend API key + a verified sender domain. Set `RESEND_API_KEY` and `EMAIL_TO` in the worker env.

**Adapter:**

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  const subject = `[Multica] ${eventType}`;
  const html = `
    <h2>Multica event</h2>
    <p><strong>Type:</strong> ${escapeHtml(eventType)}</p>
    <p><strong>Event ID:</strong> ${escapeHtml(eventId)}</p>
    <p><strong>Workspace:</strong> ${escapeHtml(payload.workspace_id || 'unknown')}</p>
    <pre>${escapeHtml(JSON.stringify(payload, null, 2))}</pre>
  `;

  const resp = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: 'multica-alerts@your-domain.com',
      to: env.EMAIL_TO,
      subject,
      html,
    }),
  });
  if (!resp.ok) throw new Error(`resend ${resp.status}: ${await resp.text()}`);
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[ch]));
}
```

---

## Recipe 3: Email via Postmark

Postmark's API shape is virtually identical to Resend; swap the URL + auth header. Use this if you already have a Postmark account.

```javascript
const resp = await fetch('https://api.postmarkapp.com/email', {
  method: 'POST',
  headers: {
    'X-Postmark-Server-Token': env.POSTMARK_TOKEN,
    Accept: 'application/json',
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({ From: 'alerts@your-domain.com', To: env.EMAIL_TO, Subject: subject, HtmlBody: html }),
});
```

Same caller code from Recipe 2 otherwise.

---

## Recipe 4: Asana task creation

**Use case:** every Multica `issue:created` becomes an Asana task in a configured project.

**Setup:** create an Asana Personal Access Token; identify the workspace `gid` and project `gid`.

**Adapter:**

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  if (eventType !== 'issue:created') return; // only mirror issue:created

  const task = {
    data: {
      name: payload.title || `Multica issue ${payload.identifier}`,
      notes: `${payload.description || ''}\n\n---\nMulticaEventId: ${eventId}\nMulticaIssue: ${payload.identifier}`,
      projects: [env.ASANA_PROJECT_GID],
      // Optional: assignee, due_on, custom_fields based on payload
    },
  };

  const resp = await fetch('https://app.asana.com/api/1.0/tasks', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.ASANA_PAT}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(task),
  });
  if (!resp.ok) throw new Error(`asana ${resp.status}: ${await resp.text()}`);
}
```

**Auth model note:** Personal Access Tokens are sufficient for single-workspace deployments. For multi-workspace SaaS use, switch to OAuth so each Multica workspace can authorize its own Asana account.

---

## Recipe 5: Notion database row creation

**Setup:** create a Notion integration, share the target database with it, copy the integration secret + database ID.

**Adapter:**

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  const properties = {
    'Title': { title: [{ text: { content: payload.title || `Multica ${payload.identifier}` } }] },
    'Multica Event ID': { rich_text: [{ text: { content: eventId } }] },
    'Type': { select: { name: eventType } },
    'Status': { select: { name: 'Open' } },
  };

  const resp = await fetch('https://api.notion.com/v1/pages', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.NOTION_TOKEN}`,
      'Notion-Version': '2022-06-28',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      parent: { database_id: env.NOTION_DATABASE_ID },
      properties,
    }),
  });
  if (!resp.ok) throw new Error(`notion ${resp.status}: ${await resp.text()}`);
}
```

The `properties` shape must match the columns in your Notion database. Adjust property names/types accordingly.

---

## Recipe 6: Jira Cloud issue creation

**Use case:** Multica events that should land as work items in Jira (e.g. `task:failed` becomes a bug in the Jira project, `autopilot:run_done` summary becomes an issue for triage).

**Setup:** create a Jira API token at `id.atlassian.com/manage-profile/security/api-tokens`. Identify your Jira host + project key.

**Adapter:**

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  if (!shouldCreateJiraIssue(eventType)) return;

  const auth = btoa(`${env.JIRA_USER_EMAIL}:${env.JIRA_API_TOKEN}`);
  const issue = {
    fields: {
      project: { key: env.JIRA_PROJECT_KEY },          // e.g. 'OPS'
      summary: formatJiraSummary(eventType, payload),
      description: formatJiraDescription(eventId, eventType, payload),
      issuetype: { name: mapJiraIssueType(eventType) }, // 'Bug' / 'Task' / 'Incident'
      labels: ['multica', `multica-event-${eventType.replace(':', '-')}`],
    },
  };

  const resp = await fetch(`https://${env.JIRA_HOST}/rest/api/3/issue`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${auth}`,
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(issue),
  });
  if (!resp.ok) throw new Error(`jira ${resp.status}: ${await resp.text()}`);
}

function shouldCreateJiraIssue(t) {
  return ['task:failed', 'webhook:auto_paused', 'autopilot:run_done'].includes(t);
}
function mapJiraIssueType(t) {
  return t === 'task:failed' ? 'Bug' : 'Task';
}
function formatJiraSummary(t, p) {
  return `[Multica/${t}] ${p.title || p.identifier || p.id || 'event'}`;
}
function formatJiraDescription(eventId, t, p) {
  // Atlassian Document Format (ADF). Plain-text version for brevity:
  return {
    version: 1,
    type: 'doc',
    content: [
      { type: 'paragraph', content: [{ type: 'text', text: `Multica event ${eventId} (${t})` }] },
      { type: 'paragraph', content: [{ type: 'text', text: JSON.stringify(p, null, 2) }] },
    ],
  };
}
```

**Back-reference pattern:** the Jira issue's description contains the Multica `eventId`, which lets you correlate later (e.g., when the inbound webhooks RFC ships, Multica can receive a `jira:issue_updated` callback and find the linked Multica issue by parsing this back-reference).

**Inverse direction:** Jira can fire its own outbound webhooks to Multica when you wire the **inbound** RFC (currently in design). The recipes here cover Multica → Jira; the reverse direction (Jira → Multica) lands when the inbound RFC's Jira provider verifier ships.

---

## Recipe 7: Bitbucket Cloud (issue creation OR pipeline trigger)

Two distinct patterns depending on what Multica should kick off in Bitbucket.

### 7a. Create an issue in a Bitbucket repo

**Setup:** create a Bitbucket App Password at `bitbucket.org/account/settings/app-passwords/` with `issue:write` scope.

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  const auth = btoa(`${env.BITBUCKET_USER}:${env.BITBUCKET_APP_PASSWORD}`);

  const resp = await fetch(
    `https://api.bitbucket.org/2.0/repositories/${env.BB_WORKSPACE}/${env.BB_REPO}/issues`,
    {
      method: 'POST',
      headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        title: `[Multica] ${payload.title || eventType}`,
        content: { raw: `Multica event ${eventId}\n\n${JSON.stringify(payload, null, 2)}`, markup: 'markdown' },
        kind: 'task',
      }),
    },
  );
  if (!resp.ok) throw new Error(`bitbucket-issue ${resp.status}: ${await resp.text()}`);
}
```

### 7b. Trigger a Bitbucket Pipeline

**Use case:** a `task:completed` event should kick off a build/deploy pipeline.

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  if (eventType !== 'task:completed') return;
  const auth = btoa(`${env.BITBUCKET_USER}:${env.BITBUCKET_APP_PASSWORD}`);

  const resp = await fetch(
    `https://api.bitbucket.org/2.0/repositories/${env.BB_WORKSPACE}/${env.BB_REPO}/pipelines/`,
    {
      method: 'POST',
      headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target: {
          ref_type: 'branch',
          type: 'pipeline_ref_target',
          ref_name: 'main',
          selector: { type: 'custom', pattern: 'multica-deploy' },
        },
        variables: [
          { key: 'MULTICA_EVENT_ID', value: eventId },
          { key: 'MULTICA_TASK_ID', value: payload.id || '' },
        ],
      }),
    },
  );
  if (!resp.ok) throw new Error(`bitbucket-pipeline ${resp.status}: ${await resp.text()}`);
}
```

Custom variables (`MULTICA_EVENT_ID`, etc.) are then available inside the pipeline as `$MULTICA_EVENT_ID`. Use this to drive deploy targets, log correlation, etc.

---

## Recipe 8: Microsoft Teams (Power Automate flow)

Two paths.

### 8a. Direct (Tier-1-style) — zero adapter

Teams has an **incoming webhook connector** for channels. Power Automate's "When an HTTP request is received" trigger gives you a URL that accepts arbitrary JSON. Set that URL directly in `multica webhook create --url <url>` and point your filter at the events you want.

For most Teams use cases this is sufficient — no adapter needed. The Power Automate flow can transform the JSON inline and post a Teams card.

### 8b. Via Logic App / Function App (Tier 2)

When you need server-side transformation (e.g. enrich the payload with data from another system before posting), set up an Azure Function or Logic App as the adapter. Same skeleton as the other recipes, with the target API being the Teams incoming-webhook URL:

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  const card = {
    '@type': 'MessageCard',
    '@context': 'http://schema.org/extensions',
    summary: `Multica ${eventType}`,
    themeColor: '0076D7',
    sections: [{
      activityTitle: `**Multica event:** ${eventType}`,
      activitySubtitle: `Event ID: ${eventId}`,
      facts: Object.entries(payload).slice(0, 6).map(([k, v]) => ({
        name: k,
        value: String(v).slice(0, 200),
      })),
    }],
  };

  const resp = await fetch(env.TEAMS_INCOMING_WEBHOOK_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(card),
  });
  if (!resp.ok) throw new Error(`teams ${resp.status}: ${await resp.text()}`);
}
```

---

## Recipe 9: Google Chat

Google Chat has incoming webhook URLs at the channel level (Workspace admin enables them). Different signing scheme from Multica's HMAC, so a thin adapter bridges.

```javascript
async function callTargetApi(eventId, eventType, payload, env) {
  const text = `*Multica event:* ${eventType}\nEvent ID: \`${eventId}\`\n\`\`\`${JSON.stringify(payload, null, 2).slice(0, 1500)}\`\`\``;

  const resp = await fetch(env.GOOGLE_CHAT_WEBHOOK_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text }),
  });
  if (!resp.ok) throw new Error(`google-chat ${resp.status}: ${await resp.text()}`);
}
```

The Google webhook URL itself is the auth — keep it secret in env. For workspaces that need stricter verification, route through a Workload Identity Federation flow + service account token instead.

---

## Verification checklist (before going live with any Tier 2 adapter)

- [ ] Adapter validates `X-Multica-Signature` using your subscription's secret (constant-time compare, not `==`)
- [ ] Adapter rate-limits or throttles outbound calls to the target API (Twilio, Resend, Asana, Notion, etc. all have their own per-account rate caps; respect them)
- [ ] Adapter returns 5xx if the target API failed (so Multica retries) — **don't** return 200 prematurely
- [ ] Adapter logs the `X-Multica-Event-Id` so you can correlate Multica deliveries to target-platform actions
- [ ] Recommended: use the `webhook:test` event for a dry-run before subscribing real events (`multica webhook test <subscription-id>`)
- [ ] If the target platform has its own retry / dedup, idempotency-key the call using `X-Multica-Event-Id` so a Multica retry doesn't double-create
- [ ] Production checklist: rotate the Multica subscription secret quarterly via `multica webhook rotate-secret <id>`; rotate target-platform API keys on the platform's recommended cadence

---

## Cost / latency table

Approximate consumer-side cost per event for each Tier 2 platform. All numbers are order-of-magnitude — verify against current pricing before committing to a high-volume integration.

| Platform | Cost per event | Latency | Recommended use |
|---|---|---|---|
| Twilio SMS | ~$0.008 (US) | ~1-2 sec | Operational alerts only |
| Resend email | ~$0.0001 (3K/month free) | ~500 ms | Reports, escalations |
| Postmark email | similar to Resend | ~500 ms | Same |
| Asana task | free (workspace plan permitting) | ~300 ms | Issue mirroring |
| Notion row | free (workspace plan permitting) | ~500 ms | Database mirroring |
| Jira Cloud issue | free (your Jira plan) | ~400 ms | Bug / task mirroring |
| Bitbucket issue | free (your Bitbucket plan) | ~400 ms | Issue mirroring |
| Bitbucket pipeline | depends on build minutes | minutes (full pipeline run) | Deploy / build trigger |
| Teams (Power Automate) | per-flow-execution pricing | ~800 ms | Channel notifications |
| Google Chat | free (Workspace plan permitting) | ~300 ms | Channel notifications |

---

## Atlassian-stack note

Jira and Bitbucket both also emit their own outbound webhooks. Multica will be able to **receive** them once the [inbound webhooks RFC](https://github.com/multica-ai/multica/issues/2373) lands as the counterpart system to RFC #1964. The recipes in this doc cover the **outbound** direction (Multica → Jira, Multica → Bitbucket); the **inbound** direction (Jira → Multica, Bitbucket → Multica) is covered by that follow-up RFC.

When both directions are wired:

- A Multica `issue:created` event creates a Jira issue (this doc).
- The Jira issue's status changes (engineer touches it) → Jira fires `jira:issue_updated` → Multica receives → updates the linked Multica issue.

That bidirectional loop replaces every form of polling for Atlassian-stack integration.

---

## Recipes for additional platforms (community contributions)

PRs welcome to add new platforms. The pattern is consistent: extend the common adapter skeleton with a `callTargetApi` implementation specific to the target. Aim for under 30 lines per recipe and a clear use-case statement.

Currently missing recipes that would be valuable additions:

- **HubSpot** (CRM contact creation on `member:added`)
- **Zendesk** (ticket creation on `task:failed`)
- **Linear** (issue creation, similar to Asana but Linear's API is simpler)
- **Salesforce** (record creation; OAuth is more involved)
- **Webflow** (CMS item creation; useful for status pages)
- **Stripe** (custom event reporting; uses Stripe's own webhook signature so the adapter only goes one way)

If you ship a recipe, follow the verification checklist above and submit as a section in this doc.

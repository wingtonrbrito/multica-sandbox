// Real output from an engineer-agent run.
// Issue: DSO-2 — "Add /api/demo-smoke-test endpoint returning {\"status\":\"ok\"}"
// Chain: orchestrator → engineer (this file)
// Engineer model: claude-sonnet-4-6
//
// Acceptance criteria satisfied:
// - GET returns 200 with {"status":"ok"} and Content-Type: application/json
// - Single-file change (no other files modified)
// - Uses NextResponse from next/server (same pattern as api-hello-route.ts)
//
// Kept here as an artifact of an actual engineer-agent run (DSO-2).

import { NextResponse } from 'next/server';

export function GET() {
  return new NextResponse(JSON.stringify({ status: 'ok' }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

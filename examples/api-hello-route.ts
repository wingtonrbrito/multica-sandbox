// Real output from an engineer-agent run.
// Issue: "Add /api/hello endpoint with strict HTTP semantics (run 3)"
// Chain: orchestrator → engineer → qa-review → CLOSE (6m 35s)
// Engineer model: claude-sonnet-4-6
// QA verdict: approved, FULL spec compliance
//
// Acceptance criteria the engineer satisfied:
// - GET returns 200 with {"hello":"world","timestamp": <ISO8601 UTC ending Z>}
// - HEAD explicitly exported (does NOT rely on Next.js auto-HEAD fallback)
// - OPTIONS returns 204 with Access-Control-Allow-Methods header
// - POST/PUT/DELETE/PATCH each return 405 with Allow header (RFC 7231 mandatory)
// - Every non-204 response has Content-Type, Vary, Cache-Control, X-Powered-By
// - JSON serialization order: hello first, timestamp second
// - Single-file change (no other files modified)
// - Uses NextResponse from next/server (not the older Response API)
//
// Kept here as an artifact, not as production code. The interesting thing is
// not that this is good Next.js — it's that an LLM agent operating from a
// natural-language spec hit every checkbox on first try.

import { NextResponse } from 'next/server';

const SHARED_HEADERS = {
  'Content-Type': 'application/json',
  'Vary': 'Accept',
  'Cache-Control': 'no-store',
  'X-Powered-By': 'multica-sandbox',
};

export function GET() {
  return new NextResponse(
    JSON.stringify({ hello: 'world', timestamp: new Date().toISOString() }),
    { status: 200, headers: SHARED_HEADERS },
  );
}

export function HEAD() {
  return new NextResponse(null, { status: 200, headers: SHARED_HEADERS });
}

export function OPTIONS() {
  return new NextResponse(null, {
    status: 204,
    headers: { 'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS' },
  });
}

function methodNotAllowed() {
  return new NextResponse(null, {
    status: 405,
    headers: { ...SHARED_HEADERS, Allow: 'GET, HEAD, OPTIONS' },
  });
}

export const POST = methodNotAllowed;
export const PUT = methodNotAllowed;
export const DELETE = methodNotAllowed;
export const PATCH = methodNotAllowed;

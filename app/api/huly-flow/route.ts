import { NextResponse } from 'next/server';

export function GET() {
  return NextResponse.json(
    { ingested_via: 'huly', timestamp: new Date().toISOString() },
    { status: 200 },
  );
}

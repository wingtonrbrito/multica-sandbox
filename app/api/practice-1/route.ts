import { NextResponse } from "next/server";

export function GET() {
  return NextResponse.json({ practice: 1, timestamp: new Date().toISOString() });
}

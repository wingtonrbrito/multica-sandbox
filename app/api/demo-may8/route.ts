import { NextResponse } from "next/server";

export function GET() {
  return NextResponse.json({ status: "ok", date: "2026-05-08" });
}

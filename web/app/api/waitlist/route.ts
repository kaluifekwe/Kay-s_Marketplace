import { NextResponse } from "next/server";
import { getSupabase } from "@/lib/supabase";
import { isEmail, STATES } from "@/lib/validate";

// The only write path on this site. Everything else here reads web_public_*
// views with the anon key; this inserts into waitlist_signups with the SAME
// anon key, gated entirely by that table's RLS policy (anon: INSERT only,
// never SELECT/UPDATE/DELETE — see waitlist_signups.sql). Validating here
// too is defense in depth, not the only guard: the DB's CHECK constraints
// and RLS policy reject anything this misses.
export async function POST(req: Request) {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ ok: false, error: "Invalid request." }, { status: 400 });
  }

  const { email, role, state } = (body ?? {}) as Record<string, unknown>;

  if (!isEmail(email)) {
    return NextResponse.json({ ok: false, error: "Enter a valid email address." }, { status: 400 });
  }
  if (role !== "buyer" && role !== "vendor") {
    return NextResponse.json({ ok: false, error: "Choose buyer or vendor." }, { status: 400 });
  }
  const cleanState = typeof state === "string" && (STATES as readonly string[]).includes(state) ? state : null;

  const supabase = getSupabase();
  const { error } = await supabase
    .from("waitlist_signups")
    .insert({ email: (email as string).toLowerCase(), role, state: cleanState, source: "blog" });

  if (error) {
    if (error.code === "23505") {
      // Unique violation on lower(email) — already on the list, not an error for them.
      return NextResponse.json({ ok: true, already: true });
    }
    console.error("waitlist insert error:", error.message);
    return NextResponse.json({ ok: false, error: "Could not save that right now. Try again shortly." }, { status: 500 });
  }

  return NextResponse.json({ ok: true, already: false });
}

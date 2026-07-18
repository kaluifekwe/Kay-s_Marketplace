// Append an entry to the admin audit log.
//
// BEST EFFORT BY DESIGN: logging must never be able to fail an admin action.
// If the insert throws (table missing, transient DB error) we log to the
// function console and carry on — a refund that succeeded must not be reported
// as failed, or rolled back, because its audit row didn't write. The trade-off
// is deliberate: a missing audit row is recoverable from the function logs, a
// wrongly-failed money action is not.
//
// Call it AFTER the action has actually succeeded, so the log reflects what
// happened rather than what was attempted.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface AuditEntry {
  adminId: string;
  action: string;                 // e.g. "dispute.approve_refund"
  targetType?: string;            // dispute | user | order | withdrawal | setting
  targetId?: string;
  summary?: string;               // human-readable, shown in the console
  metadata?: Record<string, unknown>;
}

export async function logAdminAction(entry: AuditEntry): Promise<void> {
  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    await supabase.from("admin_audit_log").insert({
      admin_id: entry.adminId,
      action: entry.action,
      target_type: entry.targetType ?? null,
      target_id: entry.targetId ?? null,
      summary: entry.summary ?? null,
      metadata: entry.metadata ?? {},
    });
  } catch (e) {
    console.error(`audit: failed to record ${entry.action} by ${entry.adminId}:`, e);
  }
}

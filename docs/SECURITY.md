# Security playbook — Kay's Marketplace

Follow this for **every new table, column, endpoint, and money/state change**.
The rules are deny-by-default; you declare *intent*, the patterns enforce the
*mechanics*. Run `verify_security.sql` before each release.

Core principle: **the anon key is public (it ships in the app), so every table
is internet-reachable. RLS + server-side writes are the only real protection.
Never trust anything the client sends.**

---

## 1. New table → lock it by default
```sql
ALTER TABLE <t> ENABLE ROW LEVEL SECURITY;   -- always
```
With RLS on and no policy, nobody can touch it. Then add only what's needed,
composing the helpers in `security_helpers.sql`:
- Owner read/write: `USING (user_id = auth.uid())` (and matching `WITH CHECK`).
- Party access: `USING (is_order_party(order_id))` / `is_chat_participant(chat_id)` / `is_store_owner(store_id)`.
- Admin: `USING (is_admin())`.
- Public catalogue (read-only, intentional): `FOR SELECT USING (true)` is OK; a
  permissive **write** (`USING(true)` on INSERT/UPDATE/DELETE/ALL) is never OK
  for client roles — scope it `TO service_role`.

## 2. Sensitive columns → never client-writable
RLS controls rows, not columns. Money / auth / identity columns
(`role`, `kays_credit`, `payout_blocked*`, `payment_released`, `total`,
`has_dispute`, dispute flags, `state`, …) must be set **only** by Edge Functions
(service role) or a SECURITY DEFINER RPC — never a direct client `UPDATE`.
Enforce with a `BEFORE UPDATE` column-guard trigger (see `harden_rls.sql`,
`secure_credit.sql`, `secure_disputes.sql`, `secure_messages.sql`). Before
guarding a column, `grep` the app for client writes to it.

## 3. Money / state changes → server-side, re-derived
- Amounts/prices: recompute from the DB; never charge the client's number
  (see `create-payment`).
- Payouts/refunds/credit/escrow transitions: Edge Functions (service role) with
  idempotency. Reconcile async results (e.g. Paystack transfer webhooks).
- Atomic balance changes via DEFINER RPCs that enforce ownership
  (`spend_kays_credit`), not client read-then-write.

## 4. Endpoints (Edge Functions)
- Keep `verify_jwt = true` (default). Only webhooks/public pages set it false —
  and those verify a signature (webhooks) or are read-only (share pages).
- Each function authorizes the action itself (JWT valid ≠ allowed): check the
  caller is the buyer/owner/admin, or it's a service-role/cron call.
- Allowlist actions (no blind proxying); keep all secrets server-side.

## 5. Notifications / cross-user writes
A client may only write rows for itself or a genuine counterparty
(`secure_notifications.sql`). Prefer creating cross-user rows server-side.

## 6. After any schema/policy change
1. Run `verify_security.sql` — it must return **zero** rows for checks 1 & 3.
2. Refresh the committed schema (Docker running):
   `cd dispatchph_mobile && supabase db dump --linked -f ../schema/live_schema.sql --schema public`
3. Commit both the migration and the refreshed dump.

## Reference files
- `security_helpers.sql` — reusable policy primitives (`is_admin`, `is_order_party`, …)
- `verify_security.sql` — the pre-release audit
- `harden_rls.sql`, `secure_credit.sql`, `secure_disputes.sql`,
  `secure_messages.sql`, `secure_notifications.sql`, `public_profiles.sql` —
  the applied hardening (worked examples of the patterns above)
- `schema/live_schema.sql` — current production schema (source of truth)

# Payout relay (Fly.io)

A tiny static-IP relay so Flutterwave payouts work from Supabase Edge Functions.
Your `wallet-withdraw` function POSTs the transfer here; this relay forwards it to
Flutterwave from **one fixed IP** that you whitelist. Flutterwave keys stay in
Supabase — only a short-lived token passes through, and the relay is locked with
a shared secret.

## One-time deploy

1. **Install the Fly CLI** and sign in:
   ```powershell
   # install (Windows PowerShell)
   iwr https://fly.io/install.ps1 -useb | iex
   fly auth signup   # or: fly auth login
   ```

2. **From this folder**, create the app (uses the included `fly.toml`; pick a
   unique name if `kays-payout-relay` is taken):
   ```powershell
   cd D:\Dev\Dispatch\payout-relay
   fly launch --no-deploy --copy-config --name kays-payout-relay --region fra
   ```

3. **Allocate a dedicated IPv4** ($2/mo — this is the IP you whitelist; a shared
   IP won't work):
   ```powershell
   fly ips allocate-v4
   ```

4. **Set the shared secret** (invent a strong random value — keep it; you'll use
   the same one in Supabase):
   ```powershell
   fly secrets set RELAY_SECRET=PASTE_A_LONG_RANDOM_STRING
   ```

5. **Deploy:**
   ```powershell
   fly deploy
   ```

6. **Get the exact outbound IP to whitelist** (this asks the relay what IP
   Flutterwave will actually see — more reliable than guessing):
   ```powershell
   # open in a browser, or:
   curl https://kays-payout-relay.fly.dev/myip
   ```
   Run it 2–3 times; it should return the **same** IP each time.

7. **Whitelist that IP in Flutterwave** → Settings → IP Whitelisting → Add IP
   address → paste the IP → Save.

## Wire it into Supabase

8. Set the relay URL + secret as Edge Function secrets (same secret as step 4):
   ```powershell
   cd D:\Dev\Dispatch\dispatchph_mobile
   supabase secrets set FLUTTERWAVE_RELAY_URL=https://kays-payout-relay.fly.dev/flw FLUTTERWAVE_RELAY_SECRET=PASTE_THE_SAME_RANDOM_STRING
   supabase functions deploy wallet-withdraw
   ```

9. In the app: **Wallet → Withdraw → ₦100 → Withdraw to bank.** It now routes
   through the relay's whitelisted IP.

## Notes
- The relay only handles **transfers**. Funding, checkout, escrow, refunds, and
  bank name-lookup already work directly (they aren't IP-gated).
- If `/myip` ever returns a different IP (Fly moved the machine), re-whitelist —
  but with the dedicated IPv4 it should stay put.
- Cost: ~$2/mo dedicated IPv4 + a few dollars for the always-on 256MB machine.

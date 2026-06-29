# Kay's Marketplace — Web (share pages)

Public, server-rendered pages for sharing the marketplace on social platforms.
Renders real `text/html` with Open Graph tags (which Supabase Edge Functions
can't do on their shared domain), so WhatsApp/Facebook/etc. show link previews.

Routes:

- `/p/[id]` — a single product
- `/store/[handle]` — a vendor's whole storefront (all listings, "buy in app").
  Accepts the clean store handle, or a raw store id as a fallback.

This is the early, minimal slice of the phase-2 website. Buying still happens in
the app; these pages are discovery + an install funnel.

## Deploy on Vercel

1. In Vercel, import this Git repo. Set **Root Directory** = `web`.
2. Framework preset: **Next.js** (auto-detected).
3. Add environment variables (Project → Settings → Environment Variables):
   - `SUPABASE_URL` = `https://takuhbkpagvhmxsncdls.supabase.co`
   - `SUPABASE_SERVICE_ROLE_KEY` = (Supabase → Project Settings → API → service_role)
   - `APP_PLAY_STORE_URL` / `APP_STORE_URL` — optional, set once published.
4. Deploy. You'll get `https://<project>.vercel.app`.

## Point the app at it

In the Flutter app's `.env`, set:

```
SHARE_BASE_URL=https://<project>.vercel.app
```

The in-app Share buttons then produce `…/p/<id>` and `…/store/<handle>` links.
Later, attach your custom domain in Vercel and update `SHARE_BASE_URL` — no code
change needed.

## Local dev

```
cd web
cp .env.example .env.local   # fill in the service-role key
npm install
npm run dev
```

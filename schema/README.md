# Database schema (source of truth)

`live_schema.sql` is a full dump of the production `public` schema from Supabase
project `takuhbkpagvhmxsncdls` — every table, RLS policy, function, trigger, and
index. Committed so the schema is reproducible and "is this safe?" is always
answerable from version control (previously the core tables — users, orders,
stores, products, chats, messages — were created outside any migration).

## Refresh after schema changes

With Docker Desktop running:

```bash
cd dispatchph_mobile
supabase db dump --linked -f ../schema/live_schema.sql --schema public
```

Commit the result. Do this whenever you apply a migration (the `*.sql` files in
the repo root) so this dump stays current.

## Note
The individual `*.sql` files in the repo root are the human-authored migrations
(apply these to a fresh/another environment). This dump is the *current state*
of production for reference and auditing.

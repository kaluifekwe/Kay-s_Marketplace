-- Security posture audit. Run before each release (or in CI). ANY rows returned
-- by the checks below = something to fix. Zero rows everywhere = good.

-- 1. Public tables with RLS DISABLED — wide open to the anon key. Must be empty.
SELECT 'RLS_DISABLED' AS issue, c.relname AS object
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity;

-- 2. RLS on but NO policies — table is locked to all clients. Usually fine
--    (deny-by-default), but review: if a feature needs client access you forgot
--    to add a policy.
SELECT 'RLS_ON_NO_POLICY' AS issue, c.relname AS object
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
  AND NOT EXISTS (
    SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = c.relname
  );

-- 3. WRITE policies open to non-service roles (USING/ WITH CHECK = true).
--    Public SELECT (catalogue) is fine; a permissive INSERT/UPDATE/DELETE/ALL is
--    NOT. Must be empty.
SELECT 'PERMISSIVE_WRITE_POLICY' AS issue,
       tablename || ' / ' || policyname AS object, cmd, roles::text AS roles
FROM pg_policies
WHERE schemaname = 'public'
  AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  AND (qual = 'true' OR with_check = 'true')
  AND NOT ('service_role' = ANY (roles));

-- 4. SECURITY DEFINER functions executable by anon/public — review each (they
--    bypass RLS, so they must enforce their own authorization).
SELECT 'DEFINER_FN_PUBLIC_EXEC' AS issue, p.proname AS object
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosecdef
  AND has_function_privilege('anon', p.oid, 'EXECUTE');

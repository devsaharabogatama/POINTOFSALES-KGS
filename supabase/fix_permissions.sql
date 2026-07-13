-- ----------------------------------------------------------------------
-- SQL SCRIPT: fix_permissions.sql
-- Grant explicit access privileges on all tables/sequences/functions
-- to standard Supabase roles (postgres, service_role, authenticated, anon)
-- ----------------------------------------------------------------------

-- 1. Grant permissions on existing objects in public schema
GRANT ALL ON ALL TABLES IN SCHEMA public TO postgres, service_role, authenticated, anon;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO postgres, service_role, authenticated, anon;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO postgres, service_role, authenticated, anon;

-- 2. Ensure future objects automatically inherit these permissions
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO postgres, service_role, authenticated, anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres, service_role, authenticated, anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres, service_role, authenticated, anon;

-- 3. Force PostgREST schema cache reload
NOTIFY pgrst, 'reload schema';

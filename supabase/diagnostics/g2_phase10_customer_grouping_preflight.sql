-- G2 phase 10 preflight: one-level Customer parent/group readiness.
-- SAFETY: SELECT-only; aggregate results only.

WITH checks AS (
    SELECT 'g2_phase8_dependency'::TEXT AS check_name,
           CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
           jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations WHERE version = '20260722010000'
    UNION ALL
    SELECT 'parent_column_state','INFO',jsonb_build_object(
        'already_exists',EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema='public' AND table_name='customers'
              AND column_name='parent_customer_id'
        ))
    UNION ALL
    SELECT 'customer_inventory','INFO',jsonb_build_object(
        'customers',count(*),'companies',count(DISTINCT company_id),
        'system_customers',count(*) FILTER (WHERE is_system_customer))
    FROM public.customers
    UNION ALL
    SELECT 'duplicate_normalized_customer_code',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('duplicate_groups',count(*))
    FROM (SELECT company_id,upper(regexp_replace(btrim(code),'\s+',' ','g'))
          FROM public.customers GROUP BY company_id,2 HAVING count(*)>1) d
    UNION ALL
    SELECT 'duplicate_normalized_customer_name',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('duplicate_groups',count(*))
    FROM (SELECT company_id,lower(regexp_replace(btrim(name),'\s+',' ','g'))
          FROM public.customers GROUP BY company_id,2 HAVING count(*)>1) d
    UNION ALL
    SELECT 'duplicate_normalized_warehouse_name',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('duplicate_groups',count(*))
    FROM (SELECT company_id,lower(regexp_replace(btrim(name),'\s+',' ','g'))
          FROM public.warehouses GROUP BY company_id,2 HAVING count(*)>1) d
    UNION ALL
    SELECT 'duplicate_normalized_uom_code',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('duplicate_groups',count(*))
    FROM (SELECT company_id,upper(regexp_replace(btrim(code),'\s+',' ','g'))
          FROM public.uoms GROUP BY company_id,2 HAVING count(*)>1) d
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

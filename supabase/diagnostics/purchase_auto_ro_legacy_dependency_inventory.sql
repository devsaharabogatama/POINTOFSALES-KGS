-- Read-only: distinguish missing historical ledger from active Receipt runtime.
SELECT 'legacy_receipt_ledger' check_name,
  COALESCE(jsonb_agg(to_jsonb(ledger) ORDER BY version),'[]'::jsonb) details
FROM private.kgs_schema_migrations ledger
WHERE version IN('20260825130000','20260825131000','20260831110000')
UNION ALL
SELECT 'active_receipt_workspace',jsonb_build_object(
  'signature',routine.oid::regprocedure::text,
  'securityDefiner',routine.prosecdef,'config',routine.proconfig,
  'definition',pg_get_functiondef(routine.oid))
FROM pg_proc routine
WHERE routine.oid=to_regprocedure('public.get_backoffice_goods_receipt_workspace()');

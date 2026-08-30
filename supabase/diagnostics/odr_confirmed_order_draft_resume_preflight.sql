-- Confirmed ODR Order leaking into legacy Draft editor preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'migration_dependencies'::TEXT check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260828100000','20260828110000')
  UNION ALL
  SELECT 'confirmed_order_exposed_by_legacy_draft_predicate',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale
  WHERE sale.document_status='DRAFT'
    AND (sale.confirmed_at IS NOT NULL OR sale.order_runtime_status NOT IN(
      'DRAFT_INPUT','SCHEDULED'))
  UNION ALL
  SELECT 'input_draft_reservation_reference',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=sale.company_id AND requirement.sales_id=sale.id
  JOIN public.sales_stock_reservation_lines line
    ON line.company_id=requirement.company_id
   AND line.stock_requirement_id=requirement.id
  WHERE sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
    AND sale.confirmed_at IS NULL
  UNION ALL
  SELECT 'runtime_routine_state',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND (
    (routine.proname='save_pos_sale_draft'
      AND pg_get_function_identity_arguments(routine.oid)='p_payload jsonb')
    OR (routine.proname='save_pos_sale_draft_with_pricelist'
      AND pg_get_function_identity_arguments(routine.oid)='p_payload jsonb')
    OR (routine.proname='list_pos_sale_drafts'
      AND pg_get_function_identity_arguments(routine.oid)='p_store_id uuid'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

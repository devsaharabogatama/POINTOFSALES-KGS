-- POS Terminal price override preflight.
-- SAFETY: SELECT-only. Run before 20260825120000_pos_terminal_price_override.sql.

WITH checks AS (
  SELECT 'migration_dependency'::TEXT AS check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END AS status,
    jsonb_build_object('ledgerRows',count(*),'requiredVersions',
      ARRAY['20260825100000','20260825110000']) AS details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260825100000','20260825110000')
  UNION ALL
  SELECT 'canonical_pos_runtime',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*),'expected',3)
  FROM unnest(ARRAY[
    'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)',
    'private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamptz)',
    'public.save_pos_terminal_ui_settings(uuid,bigint,text[])'
  ]) signature
  WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'canonical_price_snapshot_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_details
  WHERE resolved_unit_price IS NULL OR resolved_unit_price<0
  UNION ALL
  SELECT 'terminal_override_schema_state','SETUP',jsonb_build_object(
    'terminalColumnExists',EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='pos_terminals'
        AND column_name='allow_price_override'),
    'saleSnapshotColumnCount',(SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_details'
        AND column_name IN('canonical_resolved_unit_price','price_override_applied',
          'price_override_unit_price','price_override_actor_id',
          'price_override_terminal_id','price_override_session_id',
          'price_override_source','price_override_resolved_at')))
  UNION ALL
  SELECT 'terminal_runtime_inventory','INFO',jsonb_build_object(
    'terminals',count(*),
    'activeTerminals',count(*) FILTER(WHERE status='ACTIVE'))
  FROM public.pos_terminals
  UNION ALL
  SELECT 'sale_runtime_inventory','INFO',jsonb_build_object(
    'draftSales',count(*) FILTER(WHERE document_status='DRAFT'),
    'postedSales',count(*) FILTER(WHERE document_status='POSTED'),
    'saleLines',(SELECT count(*) FROM public.sales_details))
  FROM public.sales_headers
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1
  WHEN 'SETUP' THEN 2 ELSE 3 END,check_name;

-- SELECT-only preflight for inbound recovery into an already-negative balance.
WITH checks AS (
  SELECT 'inbound_recovery_dependency_ledger'::text check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    (3-count(*))::bigint violation_rows,
    jsonb_build_object('present',count(*),'expected',3,
      'requiredVersions',jsonb_build_array('20260911140000','20260914180000','20260917100000')) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260911140000','20260914180000','20260917100000')
  UNION ALL
  SELECT 'inbound_recovery_migration_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'INFO' END,0,
    jsonb_build_object('alreadyApplied',count(*)=1)
  FROM private.kgs_schema_migrations WHERE version='20260917140000'
  UNION ALL
  SELECT 'inbound_recovery_stock_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*)-2)::bigint,jsonb_build_object('present',count(*),'expected',2)
  FROM (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.stock_movements'::regclass
      AND conname='stock_movements_balance_after_controlled'
    UNION ALL
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.stock_movements'::regclass
      AND tgname='g4_guard_negative_sale_movement' AND NOT tgisinternal
  ) contract
  UNION ALL
  SELECT 'inbound_recovery_canonical_guard_shape',
    CASE WHEN definition~'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'
      AND definition~'pos_negative_stock_authorizations'
      AND definition~'backoffice_negative_stock_allocations'
      AND definition~'REVERSAL' THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN definition~'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'
      AND definition~'pos_negative_stock_authorizations'
      AND definition~'backoffice_negative_stock_allocations'
      AND definition~'REVERSAL' THEN 0 ELSE 1 END,
    jsonb_build_object('canonicalAuthorizationBranches',
      definition~'pos_negative_stock_authorizations'
      AND definition~'backoffice_negative_stock_allocations'
      AND definition~'REVERSAL')
  FROM (SELECT pg_get_functiondef(
    'private.trg_g4_guard_negative_sale_movement()'::regprocedure) definition) source
  UNION ALL
  SELECT 'inbound_recovery_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'inbound_recovery_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
), inventory AS (
  SELECT 'inbound_recovery_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'negativeStocks',(SELECT count(*) FROM public.product_stocks WHERE stock_qty<0),
      'openReceiptDrafts',(SELECT count(*) FROM public.goods_receipt_documents
        WHERE status='DRAFT' AND source_channel='BACKOFFICE')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

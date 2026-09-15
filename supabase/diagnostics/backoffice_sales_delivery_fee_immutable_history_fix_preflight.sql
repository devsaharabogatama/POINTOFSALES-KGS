-- Read-only preflight for 20260910151000 on isolated Development.
WITH definitions AS (
  SELECT pg_get_functiondef(to_regprocedure(
      'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')) core_definition,
    pg_get_functiondef(to_regprocedure(
      'private.trg_backoffice_sales_invoice_delivery_fee()')) trigger_definition
), checks AS (
  SELECT 'dependency_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910150000'
  UNION ALL
  SELECT 'forward_fix_identity_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260910151000'
  UNION ALL
  SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'required_runtime_routines',CASE WHEN count(*) FILTER(WHERE present)=4
      THEN 'PASS' ELSE 'BLOCKER' END,
    (4-count(*) FILTER(WHERE present))::bigint,
    jsonb_build_object('present',count(*) FILTER(WHERE present),'expected',4,
      'missing',COALESCE(jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE NOT present),'[]'))
  FROM (SELECT signature,to_regprocedure(signature) IS NOT NULL present FROM (VALUES
      ('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'),
      ('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)'),
      ('private.trg_backoffice_sales_invoice_delivery_fee()'),
      ('private.trg_guard_backoffice_sales_invoice_foundation_history()')
    ) required(signature)) routines
  UNION ALL
  SELECT 'immutable_history_failure_signature',
    CASE WHEN position('UPDATE public.backoffice_sales_invoice_audit SET after_state=v_after'
      in core_definition)>0
      AND position('BACKOFFICE_SALES_INVOICE_HISTORY_IMMUTABLE' in
        pg_get_functiondef(to_regprocedure(
          'private.trg_guard_backoffice_sales_invoice_foundation_history()')))>0
      THEN 'SETUP' ELSE 'BLOCKER' END,
    CASE WHEN position('UPDATE public.backoffice_sales_invoice_audit SET after_state=v_after'
      in core_definition)>0 THEN 1 ELSE 0 END::bigint,
    jsonb_build_object('wrapperUpdatesImmutableAudit',
      position('UPDATE public.backoffice_sales_invoice_audit SET after_state=v_after'
        in core_definition)>0)
  FROM definitions
  UNION ALL
  SELECT 'delivery_fee_trigger_before_fix',
    CASE WHEN position('kgs.backoffice_invoice_delivery_fee_amount' in trigger_definition)=0
      THEN 'SETUP' ELSE 'BLOCKER' END,
    0::bigint,jsonb_build_object('transactionLocalFeePresent',
      position('kgs.backoffice_invoice_delivery_fee_amount' in trigger_definition)>0)
  FROM definitions
  UNION ALL
  SELECT 'failed_behavior_fixture_inventory','INFO',0::bigint,jsonb_build_object(
    'deliveryFeeOrders',(SELECT count(*) FROM public.backoffice_sales_orders
      WHERE delivery_fee_amount>0),
    'deliveryFeeInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE delivery_fee_amount>0),
    'deliveryFeeAuditRows',(SELECT count(*) FROM public.backoffice_sales_invoice_audit
      WHERE COALESCE(after_state,'{}') ? 'deliveryFeeAmount'))
  UNION ALL
  SELECT 'preflight_environment_identity','INFO',0::bigint,jsonb_build_object(
    'database',current_database(),'databaseUser',current_user,
    'serverAddress',inet_server_addr(),'serverPort',inet_server_port())
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'SETUP' THEN 1
  WHEN 'PASS' THEN 2 ELSE 3 END,check_name;


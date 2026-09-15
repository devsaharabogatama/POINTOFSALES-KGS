-- READ ONLY. Run against production only when the user explicitly opens the
-- production-readiness gate. This script does not require Backoffice tables.
WITH checks AS (
  SELECT 'required_master_relations'::text check_name,
    CASE WHEN count(*)=7 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',7,'relationRows',count(*)) details
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'companies','stores','warehouses','customers','product_uoms','products','pricelists')
  UNION ALL
  SELECT 'required_canonical_routines',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',5,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('public.private_active_company_id()')),
    (to_regprocedure('private.acp_require_permission_capability(uuid,text,text)')),
    (to_regprocedure('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)')),
    (to_regprocedure('private.resolve_product_tax_rule(uuid,uuid,text,timestamptz)')),
    (to_regprocedure('private.calculate_tax_group(jsonb,numeric,text,text,text)'))
  ) routines(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'backoffice_sales_relation_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expectedBeforeFirstRollout',0,'relationRows',count(*),
      'relations',COALESCE(jsonb_agg(table_name ORDER BY table_name),'[]'::jsonb))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_orders','backoffice_sales_order_lines',
    'backoffice_sales_order_operations','backoffice_sales_order_audit',
    'backoffice_sales_reservations','backoffice_sales_reservation_lines',
    'backoffice_sales_delivery_orders','backoffice_sales_delivery_order_lines',
    'backoffice_sales_payment_terms','backoffice_sales_payment_term_lines',
    'backoffice_sales_proformas','backoffice_sales_invoices',
    'backoffice_sales_invoice_lines','backoffice_sales_invoice_quantity_allocations',
    'backoffice_sales_down_payment_applications',
    'backoffice_sales_invoice_receivable_schedules','backoffice_sales_invoice_audit',
    'backoffice_sales_invoice_operations','backoffice_sales_invoice_tax_breakdowns',
    'backoffice_sales_down_payment_application_tax_breakdowns')
  UNION ALL
  SELECT 'backoffice_invoice_finance_identity_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expectedBeforeRollout',0,'identityRows',count(*))
  FROM (SELECT event.system_key::text identity FROM public.system_events event
      WHERE event.system_key IN('BACKOFFICE_SALES_INVOICE','BACKOFFICE_SALES_DOWN_PAYMENT')
    UNION ALL SELECT category.id::text FROM public.transaction_categories category
      WHERE upper(regexp_replace(btrim(category.category_code),'\s+',' ','g'))
        IN('BO-SALE-INVOICE','BO-SALE-DOWN-PAYMENT')
      OR lower(regexp_replace(btrim(category.category_name),'\s+',' ','g'))
        IN('backoffice invoice penjualan','backoffice uang muka penjualan')) collision
  UNION ALL
  SELECT 'backoffice_invoice_posting_runtime_identity_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expectedBeforeRollout',0,'routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='public' AND proc.proname IN(
      'post_backoffice_sales_invoice','set_backoffice_sales_invoice_down_payments'))
    OR (namespace.nspname='private' AND proc.proname IN(
      'rebuild_backoffice_sales_invoice_dp_applications',
      'require_backoffice_sales_invoice_post_permission',
      'trg_auto_apply_backoffice_sales_invoice_dp',
      'post_backoffice_sales_invoice_financial_event_core',
      'post_financial_event_core_pre_backoffice_invoice',
      'f4b_financial_event_supported_pre_backoffice_invoice',
      'trg_guard_backoffice_sales_dp_application_tax_history',
      'trg_delete_backoffice_sales_dp_application_children'))
  UNION ALL
  SELECT 'retail_delivery_invoice_coupling','DESIGN_MIGRATION_REQUIRED',
    jsonb_build_object(
      'invoiceSnapshotRequired',EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='sales_delivery_documents'
          AND column_name='invoice_snapshot_id' AND is_nullable='NO'),
      'reason','Backoffice DO must exist before Invoice; retail Delivery constraints cannot be bypassed')
  UNION ALL
  SELECT 'production_backoffice_chain_state','INFO',jsonb_build_object(
    'ledgerRows',count(*),'expectedBeforeRollout',0,
    'auditedThrough','20260909161000')
  FROM private.kgs_schema_migrations
  WHERE version BETWEEN '20260908100000' AND '20260909161000'
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'DESIGN_MIGRATION_REQUIRED' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;

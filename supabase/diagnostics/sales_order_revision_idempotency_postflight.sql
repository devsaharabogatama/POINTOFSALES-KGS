-- Sales Order revision idempotency namespace forward-fix closing gate.
-- SAFETY: SELECT-only.
WITH definition AS (
  SELECT regexp_replace(COALESCE(pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure),''),
    '[[:space:]]+','','g') body
), sample AS (
  SELECT '00000000-0000-0000-0000-000000000001'::UUID root_key
), keys AS (
  SELECT root_key,
    private.sales_order_revision_child_idempotency_key(
      root_key,'CANCEL_SOURCE') cancel_key,
    private.sales_order_revision_child_idempotency_key(
      root_key,'CONFIRM_REPLACEMENT') confirm_key
  FROM sample
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260903120000'
  UNION ALL
  SELECT 'revision_child_idempotency_separation',
    CASE WHEN cancel_key<>confirm_key AND cancel_key<>root_key
      AND confirm_key<>root_key THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN cancel_key<>confirm_key AND cancel_key<>root_key
      AND confirm_key<>root_key THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('distinctChildren',cancel_key<>confirm_key,
      'distinctFromRoot',cancel_key<>root_key AND confirm_key<>root_key)
  FROM keys
  UNION ALL
  SELECT 'revision_confirm_namespace_contract',
    CASE WHEN body~'CANCEL_SOURCE' AND body~'CONFIRM_REPLACEMENT'
      AND body~'cancel_pos_sales_order\(v_source.id,v_source.master_version,v_cancel_key'
      AND body~'confirm_pos_sales_order_before_revision_core\(p_sales_id,p_master_version,v_confirm_key'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body~'CANCEL_SOURCE' AND body~'CONFIRM_REPLACEMENT'
      AND body~'cancel_pos_sales_order\(v_source.id,v_source.master_version,v_cancel_key'
      AND body~'confirm_pos_sales_order_before_revision_core\(p_sales_id,p_master_version,v_confirm_key'
      THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('routineRows',CASE WHEN body='' THEN 0 ELSE 1 END)
  FROM definition
  UNION ALL
  SELECT 'private_revision_child_key_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM (VALUES('anon'),('authenticated')) role_name(name)
  WHERE has_function_privilege(role_name.name,
    'private.sales_order_revision_child_idempotency_key(uuid,text)','EXECUTE')
  UNION ALL
  SELECT 'pending_revision_atomic_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
    AND replacement.id=revision.replacement_sales_id
  WHERE revision.status='PENDING' AND (
    source.document_status<>'DRAFT'
    OR source.order_runtime_status NOT IN('CONFIRMED','RESERVED')
    OR replacement.document_status<>'DRAFT'
    OR replacement.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED')
    OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=revision.company_id
        AND reservation.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=revision.company_id
        AND invoice.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=revision.company_id
        AND delivery.sales_id=revision.replacement_sales_id))
  UNION ALL
  SELECT 'revision_idempotency_runtime_inventory','INFO',0::BIGINT,
    jsonb_build_object('pending',count(*) FILTER(WHERE status='PENDING'),
      'applied',count(*) FILTER(WHERE status='APPLIED'),
      'abandoned',count(*) FILTER(WHERE status='ABANDONED'))
  FROM public.sales_order_revisions
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

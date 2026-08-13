-- ACP-5H preflight: Sales Return management and independent Cashier draft path.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260803010000'),('20260803020000'),('20260811150000'),
    ('20260813040000')
), expected_relations(relation_name) AS (
  VALUES ('sales_return_documents'),('sales_return_lines'),
    ('sales_return_refunds'),('sales_return_fifo_restorations'),
    ('sales_return_audit')
), runtime_routines AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  WHERE procedure.oid IN(
    to_regprocedure('public.list_returnable_sales(text,integer)'),
    to_regprocedure('public.save_sales_return_draft(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'),
    to_regprocedure('public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)'),
    to_regprocedure('public.post_sales_return(uuid,bigint,uuid)'),
    to_regprocedure('public.cancel_sales_return_draft(uuid,bigint,text)')
  )
), checks AS (
  SELECT 'acp_phase5h_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger ON ledger.version=required.version

  UNION ALL
  SELECT 'sales_return_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      enforcement_status='SHADOW' AND is_customizable
      AND view_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
      AND approver_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[]
      AND supported_capabilities @> ARRAY[
        'VIEW','REVIEW','POST','CANCEL_FINAL']::TEXT[]
      AND cardinality(supported_capabilities)=4
    )=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
        (SELECT to_jsonb(supported_capabilities)
         FROM public.access_permission_catalog
         WHERE permission_key='sales.sales_returns'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='sales.sales_returns'

  UNION ALL
  SELECT 'canonical_sales_return_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
        FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
  FROM expected_relations expected
  LEFT JOIN pg_class relation ON relation.relname=expected.relation_name
    AND relation.relnamespace='public'::regnamespace

  UNION ALL
  SELECT 'canonical_sales_return_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_sales_returns(text)') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Backoffice list/detail with sales.sales_returns VIEW',
        'return Return document, lines, refunds, actors and document proof only',
        'include narrow Customer, Store, Session and Warehouse labels',
        'do not expose unrelated Sale, Stock, Payment or Finance ledgers'))

  UNION ALL
  SELECT 'canonical_cashier_return_source_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_pos_returnable_sales(text,integer)') IS NOT NULL,
      'required_design',jsonb_build_array(
        'require active open Cashier session and Store scope',
        'return server-derived remaining quantity and refundable amount',
        'include delivery-fee decision state and damaged Warehouse references',
        'remove PWA direct reads of Sale detail/header and Return documents'))

  UNION ALL
  SELECT 'sales_return_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Backoffice Return table reads with one VIEW-guarded RPC',
        'replace PWA source and own-Draft reads with open-session RPCs',
        'revoke five dedicated Return table SELECT only after both consumers migrate',
        'retain server-authoritative posting and cashier cash calculation'))
  FROM (SELECT expected.relation_name,has_table_privilege(
    'authenticated',format('public.%I',expected.relation_name),'SELECT') readable
    FROM expected_relations expected) privilege_state

  UNION ALL
  SELECT 'sales_return_channel_authority_split','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Cashier source search and Draft save remain open-session and Store scoped',
      'Backoffice VIEW never grants Cashier Draft authority',
      'POST is the final approval action and remains Manager/Admin authority',
      'CANCEL_FINAL applies only to eligible Draft cancellation',
      'custom permission may restrict but never widen Store or Company scope'))

  UNION ALL
  SELECT 'sales_return_review_capability_decision','REVIEW',
    jsonb_build_object(
      'current_lifecycle',jsonb_build_array('DRAFT','POSTED','CANCELED'),
      'decision','VIEW provides review screen and POST performs the atomic approval',
      'required_design',jsonb_build_array(
        'do not invent a new reviewed state during ACP cutover',
        'POST must remain unavailable to LIHAT_SAJA and OPERASIONAL presets',
        'retain REVIEW in catalog for compatibility but never treat it as final effect'))

  UNION ALL
  SELECT 'sales_return_finance_boundary','REVIEW',
    jsonb_build_object('hold_events',(SELECT count(*) FROM public.financial_events
      WHERE event_type='SALES_REFUND'::public.event_type AND status='HOLD'),
      'required_design',jsonb_build_array(
        'posting creates one SALES_REFUND financial event through canonical core',
        'ACP does not release Finance HOLD or create Journal entries',
        'refund, tax, FIFO cost and delivery-fee decision snapshots remain immutable'))

  UNION ALL
  SELECT 'sales_return_bundle_consumer_scope','REVIEW',
    jsonb_build_object('required_design',jsonb_build_array(
      'Bundle Return restores component FIFO from immutable Sale allocations',
      'Sales Return never inherits sales.bundles MANAGE',
      'partial and full Return quantity remain source-line bounded'))

  UNION ALL
  SELECT 'sales_return_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%sales.sales_returns%'),
      'routine_names',COALESCE(jsonb_agg(proname ORDER BY proname),
        '[]'::JSONB))
  FROM runtime_routines

  UNION ALL
  SELECT 'sales_return_routine_state',
    CASE WHEN count(DISTINCT proname)=5
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=5
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routine_names',COALESCE(
      jsonb_agg(DISTINCT proname ORDER BY proname),'[]'::JSONB),
      'signature_rows',count(*),'authenticated_executable_rows',count(*) FILTER(
        WHERE has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_executable_rows',count(*) FILTER(
        WHERE has_function_privilege('anon',oid,'EXECUTE')))
  FROM runtime_routines

  UNION ALL
  SELECT 'sales_return_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE writable),
      '[]'::JSONB))
  FROM (SELECT expected.relation_name,has_table_privilege(
    'authenticated',format('public.%I',expected.relation_name),
    'INSERT,UPDATE,DELETE') writable FROM expected_relations expected) write_state

  UNION ALL
  SELECT 'sales_return_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
  WHERE override_row.permission_key='sales.sales_returns'
    AND membership.user_id IS NULL

  UNION ALL
  SELECT 'invalid_sales_return_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.sales_return_documents document
  WHERE (document.status='DRAFT' AND (document.posted_at IS NOT NULL
      OR document.canceled_at IS NOT NULL OR document.financial_event_id IS NOT NULL))
     OR (document.status='POSTED' AND (document.posted_at IS NULL
      OR document.posted_by IS NULL OR document.financial_event_id IS NULL
      OR document.posting_idempotency_key IS NULL))
     OR (document.status='CANCELED' AND (document.canceled_at IS NULL
      OR document.canceled_by IS NULL OR NULLIF(btrim(document.cancel_reason),'') IS NULL))

  UNION ALL
  SELECT 'sales_return_header_line_refund_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.sales_return_documents document
  WHERE document.refund_total<>COALESCE((SELECT sum(refund.amount)
    FROM public.sales_return_refunds refund
    WHERE refund.company_id=document.company_id
      AND refund.document_id=document.id),0)
     OR document.refund_before_rounding<COALESCE((SELECT sum(
       line.refund_before_rounding) FROM public.sales_return_lines line
       WHERE line.company_id=document.company_id
         AND line.document_id=document.id),0)

  UNION ALL
  SELECT 'cumulative_sales_return_quantity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('source_line_count',count(*))
  FROM (SELECT detail.company_id,detail.id,detail.qty,
      COALESCE(sum(line.quantity_uom) FILTER(
        WHERE document.status='POSTED'),0) returned_qty
    FROM public.sales_details detail
    LEFT JOIN public.sales_return_lines line
      ON line.company_id=detail.company_id
     AND line.source_sales_detail_id=detail.id
    LEFT JOIN public.sales_return_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    GROUP BY detail.company_id,detail.id,detail.qty) source_line
  WHERE returned_qty>qty

  UNION ALL
  SELECT 'posted_sales_return_final_effect_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.sales_return_documents document
  LEFT JOIN public.financial_events event ON event.company_id=document.company_id
    AND event.id=document.financial_event_id
  WHERE document.status='POSTED' AND (event.id IS NULL
    OR event.source_table<>'sales_return_documents'
    OR event.source_id<>document.id
    OR event.event_type<>'SALES_REFUND'::public.event_type)

  UNION ALL
  SELECT 'posted_physical_return_fifo_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('line_count',count(*))
  FROM public.sales_return_lines line
  JOIN public.sales_return_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  WHERE document.status='POSTED'
    AND line.return_condition<>'NO_PHYSICAL_RETURN'
    AND NOT EXISTS(SELECT 1 FROM public.sales_return_fifo_restorations restoration
      WHERE restoration.company_id=line.company_id
        AND restoration.return_line_id=line.id)

  UNION ALL
  SELECT 'delivery_fee_refund_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.sales_return_documents document
  WHERE (document.delivery_fee_refund_requested
      AND document.delivery_fee_refund_amount<>
        document.source_delivery_fee_amount_snapshot)
     OR (NOT document.delivery_fee_refund_requested
      AND document.delivery_fee_refund_amount<>0)

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM (SELECT stock.company_id,stock.product_id,stock.warehouse_id
    FROM public.product_stocks stock LEFT JOIN (
      SELECT company_id,product_id,warehouse_id,sum(qty_remaining) fifo_qty
      FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
    ) fifo ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
      AND fifo.warehouse_id=stock.warehouse_id
    WHERE stock.stock_qty<>COALESCE(fifo.fifo_qty,0)) mismatch

  UNION ALL
  SELECT 'sales_return_runtime_inventory','INFO',
    jsonb_build_object(
      'companies',(SELECT count(DISTINCT company_id)
        FROM public.sales_return_documents),
      'documents',(SELECT count(*) FROM public.sales_return_documents),
      'drafts',(SELECT count(*) FROM public.sales_return_documents
        WHERE status='DRAFT'),
      'posted',(SELECT count(*) FROM public.sales_return_documents
        WHERE status='POSTED'),
      'canceled',(SELECT count(*) FROM public.sales_return_documents
        WHERE status='CANCELED'),
      'lines',(SELECT count(*) FROM public.sales_return_lines),
      'refunds',(SELECT count(*) FROM public.sales_return_refunds),
      'fifo_restorations',(SELECT count(*)
        FROM public.sales_return_fifo_restorations),
      'delivery_fee_refunds',(SELECT count(*)
        FROM public.sales_return_documents
        WHERE delivery_fee_refund_amount>0),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='sales.sales_returns'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'BACKFILL' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,
  check_name;

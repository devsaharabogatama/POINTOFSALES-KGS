-- ACP-5E preflight: Sales Invoice and Delivery Document permission boundary.
-- SAFETY: one SELECT statement; aggregate metadata only; no business identity.

WITH required_versions(version) AS (
  VALUES ('20260811130000'),('20260811140000'),('20260811143000'),
    ('20260811150000'),('20260813010000')
), expected_relations(relation_name) AS (
  VALUES ('sales_invoice_snapshots'),('sales_delivery_documents'),
    ('sales_delivery_lines'),('sales_document_audit')
), runtime_names(routine_name,required_capability) AS (
  VALUES
    ('get_sales_invoice_document','VIEW'),
    ('get_sales_delivery_document','VIEW'),
    ('record_sales_document_print','VIEW'),
    ('update_sales_delivery_status','MANAGE')
), runtime_routines AS (
  SELECT procedure.oid,procedure.proname,names.required_capability,
    pg_get_functiondef(procedure.oid) definition
  FROM runtime_names names
  LEFT JOIN pg_proc procedure ON procedure.proname=names.routine_name
    AND procedure.pronamespace='public'::regnamespace
), posted_sales AS (
  SELECT sale.* FROM public.sales_headers sale
  WHERE sale.document_status='POSTED'
), event_counts AS (
  SELECT sale.company_id,sale.id,count(event.id) event_count
  FROM posted_sales sale
  LEFT JOIN public.financial_events event
    ON event.company_id=sale.company_id
   AND event.source_table='sales_headers'
   AND event.source_id=sale.id
   AND event.event_type='SALE_POSTED'::public.event_type
  GROUP BY sale.company_id,sale.id
), checks AS (
  SELECT 'acp_phase5e_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(required.version ORDER BY required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger
    ON ledger.version=required.version

  UNION ALL
  SELECT 'sales_document_permission_catalog_state',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      enforcement_status='SHADOW' AND is_customizable
      AND view_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'
      ]::TEXT[]
      AND operator_roles=ARRAY[
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
      ]::TEXT[]
      AND supported_capabilities @> ARRAY['VIEW','MANAGE','EXPORT']::TEXT[]
    )=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB),'capabilities',COALESCE(
        (SELECT to_jsonb(supported_capabilities)
         FROM public.access_permission_catalog
         WHERE permission_key='sales.sales_documents'),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='sales.sales_documents'

  UNION ALL
  SELECT 'canonical_sales_document_schema_state',
    CASE WHEN count(*) FILTER(WHERE relation.oid IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(
      jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
        FILTER(WHERE relation.oid IS NULL),'[]'::JSONB))
  FROM expected_relations expected
  LEFT JOIN pg_class relation ON relation.relname=expected.relation_name
    AND relation.relnamespace='public'::regnamespace

  UNION ALL
  SELECT 'canonical_sales_document_composed_read_state','SETUP',
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_sales_documents()') IS NOT NULL,
      'required_design',jsonb_build_array(
        'guard Backoffice list and detail with sales.sales_documents VIEW',
        'return Invoice, Delivery, lines, Customer and Store labels in one bounded response',
        'return only document-scoped print, delivery and audit proof',
        'do not expose unrelated POS, Return, Stock, Payment or Finance ledgers'))

  UNION ALL
  SELECT 'sales_document_direct_read_cutover_scope','REVIEW',
    jsonb_build_object('authenticated_read_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE readable),
      '[]'::JSONB),'required_design',jsonb_build_array(
        'replace Backoffice dedicated-table reads with one VIEW-guarded composed RPC',
        'move PWA final Invoice lookup to its own posted-Sale-authorized RPC',
        'revoke dedicated document table SELECT only after every active consumer migrates',
        'do not revoke shared Sale table reads in this key'))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),'SELECT') readable
    FROM expected_relations expected
  ) privilege_state

  UNION ALL
  SELECT 'sales_document_channel_authority_split','REVIEW',
    jsonb_build_object(
      'view_roles',jsonb_build_array(
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'),
      'management_roles',jsonb_build_array(
        'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'),
      'required_design',jsonb_build_array(
        'VIEW authorizes Backoffice list, detail and audited print',
        'MANAGE authorizes only Delivery dispatch, deliver and cancel lifecycle',
        'EXPORT never follows VIEW implicitly',
        'POS checkout and finalization never inherit Backoffice document authority'))

  UNION ALL
  SELECT 'sales_document_shared_consumer_scope','REVIEW',
    jsonb_build_object('consumer_paths',jsonb_build_array(
      'PWA posted Sale receipt and final Invoice print',
      'Sales Return source Invoice lookup',
      'Finance Sale event and journal evidence',
      'Global Data Exchange export'),
      'required_design',jsonb_build_array(
        'each consumer authorizes its own permission or open-session Sale scope',
        'Sales Return never inherits sales.sales_documents MANAGE',
        'Finance evidence remains read-only and journal authority stays separate',
        'client-supplied purpose never bypasses effective permission'))

  UNION ALL
  SELECT 'sales_document_export_permission_state','SETUP',
    jsonb_build_object('required_design',jsonb_build_array(
      'Sales document export requires sales.sales_documents EXPORT',
      'export uses immutable Invoice and Delivery snapshots only',
      'no import capability exists for final Sales documents'))

  UNION ALL
  SELECT 'sales_document_runtime_permission_hook_state','SETUP',
    jsonb_build_object('routine_rows',count(*) FILTER(WHERE oid IS NOT NULL),
      'hooked_rows',count(*) FILTER(WHERE oid IS NOT NULL
        AND definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%sales.sales_documents%'),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname)
        FILTER(WHERE oid IS NOT NULL),'[]'::JSONB))
  FROM runtime_routines

  UNION ALL
  SELECT 'sales_document_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE writable)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(
      jsonb_agg(relation_name ORDER BY relation_name) FILTER(WHERE writable),
      '[]'::JSONB))
  FROM (
    SELECT expected.relation_name,has_table_privilege(
      'authenticated',format('public.%I',expected.relation_name),
      'INSERT,UPDATE,DELETE') writable
    FROM expected_relations expected
  ) write_state

  UNION ALL
  SELECT 'sales_document_runtime_routine_state',
    CASE WHEN count(DISTINCT proname) FILTER(WHERE oid IS NOT NULL)=
      (SELECT count(*) FROM runtime_names)
      AND count(DISTINCT proname) FILTER(WHERE oid IS NOT NULL AND
        has_function_privilege('authenticated',oid,'EXECUTE'))=
      (SELECT count(*) FROM runtime_names)
      AND count(*) FILTER(WHERE oid IS NOT NULL AND
        has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',(SELECT count(*) FROM runtime_names),
      'routine_names',COALESCE(jsonb_agg(DISTINCT proname ORDER BY proname)
        FILTER(WHERE oid IS NOT NULL),'[]'::JSONB),
      'authenticated_executable_rows',count(*) FILTER(WHERE oid IS NOT NULL
        AND has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_executable_rows',count(*) FILTER(WHERE oid IS NOT NULL
        AND has_function_privilege('anon',oid,'EXECUTE')))
  FROM runtime_routines

  UNION ALL
  SELECT 'sales_document_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
  WHERE override_row.permission_key='sales.sales_documents'
    AND membership.user_id IS NULL

  UNION ALL
  SELECT 'posted_sale_invoice_snapshot_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('sale_count',count(*))
  FROM posted_sales sale
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
  WHERE invoice.id IS NULL

  UNION ALL
  SELECT 'invoice_snapshot_source_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.sales_invoice_snapshots invoice
  LEFT JOIN public.sales_headers sale
    ON sale.company_id=invoice.company_id AND sale.id=invoice.sales_id
  WHERE sale.id IS NULL OR sale.document_status<>'POSTED'
     OR invoice.invoice_no IS DISTINCT FROM sale.invoice_no
     OR NOT (invoice.snapshot_payload ? 'company'
       AND invoice.snapshot_payload ? 'store'
       AND invoice.snapshot_payload ? 'customer'
       AND invoice.snapshot_payload ? 'lines'
       AND invoice.snapshot_payload ? 'payments'
       AND invoice.snapshot_payload ? 'totals')

  UNION ALL
  SELECT 'sales_delivery_tenant_reference_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
  FROM public.sales_delivery_documents delivery
  LEFT JOIN public.sales_headers sale
    ON sale.company_id=delivery.company_id AND sale.id=delivery.sales_id
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=delivery.company_id
   AND invoice.id=delivery.invoice_snapshot_id
  LEFT JOIN public.stores store
    ON store.company_id=delivery.company_id AND store.id=delivery.store_id
  LEFT JOIN public.warehouses warehouse
    ON warehouse.company_id=delivery.company_id
   AND warehouse.id=delivery.warehouse_id
  LEFT JOIN public.customers customer
    ON customer.company_id=delivery.company_id
   AND customer.id=delivery.customer_id
  WHERE sale.id IS NULL OR invoice.id IS NULL OR store.id IS NULL
     OR warehouse.id IS NULL
     OR (delivery.customer_id IS NOT NULL AND customer.id IS NULL)
     OR invoice.sales_id<>delivery.sales_id

  UNION ALL
  SELECT 'delivery_sale_document_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('sale_count',count(*))
  FROM posted_sales sale
  LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
  WHERE (sale.fulfillment_mode='DELIVERY'
      AND (delivery.id IS NULL OR sale.sj_no IS DISTINCT FROM delivery.delivery_no))
     OR (sale.fulfillment_mode='PICKUP' AND delivery.id IS NOT NULL)

  UNION ALL
  SELECT 'delivery_line_source_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('document_count',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE (SELECT count(*) FROM public.sales_delivery_lines line
    WHERE line.company_id=delivery.company_id
      AND line.delivery_document_id=delivery.id)<>
    (SELECT count(*) FROM public.sales_details detail
    WHERE detail.company_id=delivery.company_id
      AND detail.sales_id=delivery.sales_id)

  UNION ALL
  SELECT 'invalid_sales_delivery_lifecycle',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE delivery.master_version<=0
     OR (delivery.status='READY' AND (delivery.dispatched_at IS NOT NULL
       OR delivery.delivered_at IS NOT NULL OR delivery.canceled_at IS NOT NULL))
     OR (delivery.status='DISPATCHED' AND (delivery.dispatched_at IS NULL
       OR delivery.dispatched_by IS NULL OR delivery.delivered_at IS NOT NULL
       OR delivery.canceled_at IS NOT NULL))
     OR (delivery.status='DELIVERED' AND (delivery.dispatched_at IS NULL
       OR delivery.dispatched_by IS NULL OR delivery.delivered_at IS NULL
       OR delivery.delivered_by IS NULL OR delivery.canceled_at IS NOT NULL))
     OR (delivery.status='CANCELED' AND (delivery.canceled_at IS NULL
       OR delivery.canceled_by IS NULL
       OR COALESCE(btrim(delivery.cancel_reason),'')=''))

  UNION ALL
  SELECT 'duplicate_sales_document_number',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*))
  FROM (
    SELECT company_id,document_no FROM (
      SELECT company_id,invoice_no document_no
      FROM public.sales_invoice_snapshots
      UNION ALL
      SELECT company_id,delivery_no document_no
      FROM public.sales_delivery_documents
    ) document_number
    GROUP BY company_id,document_no HAVING count(*)>1
  ) duplicate_group

  UNION ALL
  SELECT 'posted_sale_single_financial_event_preserved',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('sale_count',count(*))
  FROM event_counts WHERE event_count<>1

  UNION ALL
  SELECT 'sales_document_runtime_inventory','INFO',
    jsonb_build_object(
      'posted_sales',(SELECT count(*) FROM posted_sales),
      'online_posted_sales',(SELECT count(*) FROM posted_sales
        WHERE source_channel='ONLINE'),
      'offline_posted_sales',(SELECT count(*) FROM posted_sales
        WHERE source_channel='OFFLINE'),
      'invoice_snapshots',(SELECT count(*)
        FROM public.sales_invoice_snapshots),
      'delivery_documents',(SELECT count(*)
        FROM public.sales_delivery_documents),
      'delivery_lines',(SELECT count(*) FROM public.sales_delivery_lines),
      'document_audit_rows',(SELECT count(*)
        FROM public.sales_document_audit),
      'delivery_fee_sales',(SELECT count(*) FROM posted_sales
        WHERE delivery_fee_amount>0),
      'override_rows',(SELECT count(*)
        FROM public.user_company_permission_overrides
        WHERE permission_key='sales.sales_documents'))
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
  WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3
  WHEN 'PASS' THEN 4 ELSE 5 END,check_name;

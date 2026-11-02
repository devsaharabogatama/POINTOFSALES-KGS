-- SELECT-only Production preflight for direct Retail POS posting.
-- Expected first-run classification: NOT_INSTALLED with every contract PASS.
WITH scope AS (
  SELECT
    '20261030120000'::text AS target_version,
    to_regprocedure('public.post_pos_sale_with_pricelist(uuid,bigint,uuid)') AS post_rpc,
    COALESCE((SELECT pg_get_functiondef(
      'public.post_pos_sale_with_pricelist(uuid,bigint,uuid)'::regprocedure)), '') AS post_rpc_definition,
    COALESCE((SELECT pg_get_functiondef(
      'public.post_pos_sale(uuid,bigint,uuid)'::regprocedure)), '') AS public_post_definition,
    COALESCE(pg_get_functiondef(to_regprocedure(
      'private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)')), '') AS retail_identity_definition,
    to_regprocedure('public.adopt_backoffice_cutover_sale_draft(uuid,bigint,uuid,uuid,boolean)') AS cutover_adoption_rpc,
    to_regprocedure('private.trg_pos_retail_direct_post_order_runtime_bridge()') AS bridge_function,
    to_regclass('public.sales_stock_reservations') AS reservation_table,
    to_regclass('public.company_sales_process_settings') AS process_setting_table,
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260811130000','20260827153000','20260828100000',
        '20260908100000','20260911120000','20260911130000')) AS dependency_rows,
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261030120000') AS target_ledger_rows,
    (SELECT count(*) FROM pg_trigger trigger_row
      JOIN pg_class relation ON relation.oid=trigger_row.tgrelid
      JOIN pg_namespace schema_row ON schema_row.oid=relation.relnamespace
      WHERE schema_row.nspname='public' AND relation.relname='sales_headers'
        AND trigger_row.tgname='pos_retail_direct_post_order_runtime_bridge'
        AND NOT trigger_row.tgisinternal) AS bridge_trigger_rows,
    COALESCE((SELECT pg_get_constraintdef(constraint_row.oid)
      FROM pg_constraint constraint_row
      JOIN pg_class relation ON relation.oid=constraint_row.conrelid
      JOIN pg_namespace schema_row ON schema_row.oid=relation.relnamespace
      WHERE schema_row.nspname='public' AND relation.relname='sales_headers'
        AND constraint_row.conname='sales_headers_order_runtime_shape'),'') AS runtime_shape,
    COALESCE((SELECT pg_get_constraintdef(constraint_row.oid)
      FROM pg_constraint constraint_row
      JOIN pg_class relation ON relation.oid=constraint_row.conrelid
      JOIN pg_namespace schema_row ON schema_row.oid=relation.relnamespace
      WHERE schema_row.nspname='public' AND relation.relname='sales_headers'
        AND constraint_row.conname='sales_headers_fulfillment_shape_check'),'') AS fulfillment_shape
), kgs AS (
  SELECT company.id,company.company_code,company.company_name,company.status,
    setting.active_mode
  FROM public.companies company
  LEFT JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE company.company_code='KGS'
), exact_draft AS (
  SELECT sale.id,sale.company_id,sale.draft_no,sale.document_status,
    sale.order_runtime_status,sale.fulfillment_mode,sale.sj_required,
    sale.sales_origin,sale.sales_process_mode,sale.master_version,
    sale.confirmed_at,sale.confirmed_by,sale.confirmation_idempotency_key,
    sale.reservation_version,sale.session_id,session_row.status AS session_status,
    sale.created_by,
    (SELECT count(*) FROM public.sales_payments payment
      WHERE payment.company_id=sale.company_id AND payment.sales_id=sale.id) AS payment_rows,
    (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.company_id=sale.company_id
        AND movement.reference_table='sales_headers' AND movement.reference_id=sale.id) AS movement_rows,
    (SELECT count(*) FROM public.financial_events event
      WHERE event.company_id=sale.company_id
        AND event.source_table='sales_headers' AND event.source_id=sale.id) AS event_rows,
    (SELECT count(*) FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=sale.company_id AND invoice.sales_id=sale.id) AS invoice_rows,
    (SELECT count(*) FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id) AS delivery_rows,
    (SELECT count(*) FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=sale.company_id AND reservation.sales_id=sale.id) AS reservation_rows
  FROM public.sales_headers sale JOIN kgs ON kgs.id=sale.company_id
  LEFT JOIN public.cashier_sessions session_row
    ON session_row.company_id=sale.company_id AND session_row.id=sale.session_id
  WHERE sale.draft_no='DRF-20261030-000455'
), cutover_inventory AS (
  SELECT count(*)::int AS rows,
    count(*) FILTER(WHERE sale.session_id IS NULL AND sale.pos_id IS NULL
      AND sale.created_session_id IS NULL)::int AS detached_rows,
    count(*) FILTER(WHERE sale.session_id IS NOT NULL AND sale.pos_id IS NOT NULL
      AND sale.created_session_id IS NOT NULL)::int AS adopted_rows,
    count(*) FILTER(WHERE NOT ((sale.session_id IS NULL AND sale.pos_id IS NULL
      AND sale.created_session_id IS NULL) OR (sale.session_id IS NOT NULL
      AND sale.pos_id IS NOT NULL AND sale.created_session_id IS NOT NULL)))::int
      AS invalid_identity_rows,
    count(*) FILTER(WHERE sale.session_id IS NOT NULL
      AND COALESCE((sale.payload_snapshot->>'snapshotPreserved')::boolean,false)
        IS NOT TRUE)::int AS adopted_without_snapshot_rows
  FROM public.sales_headers sale
  WHERE sale.sales_origin='BACKOFFICE_CUTOVER'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='DRAFT'
    AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
), checks AS (
  SELECT 10 AS seq,'pos_retail_direct_post_company_identity'::text AS check_name,
    CASE WHEN (SELECT count(*) FROM kgs)=1
      AND (SELECT active_mode FROM kgs)='RETAIL_CONFIRM_INVOICE'
      AND (SELECT status FROM kgs)='ACTIVE' THEN 'PASS' ELSE 'BLOCKER' END AS status,
    CASE WHEN (SELECT count(*) FROM kgs)=1
      AND (SELECT active_mode FROM kgs)='RETAIL_CONFIRM_INVOICE'
      AND (SELECT status FROM kgs)='ACTIVE' THEN 0 ELSE 1 END AS violation_rows,
    COALESCE((SELECT jsonb_build_object('id',id,'code',company_code,'name',company_name,
      'status',status,'activeMode',active_mode) FROM kgs),'{}'::jsonb) AS details
  UNION ALL
  SELECT 20,'pos_retail_direct_post_dependency_contract',
    CASE WHEN scope.dependency_rows=6 AND scope.post_rpc IS NOT NULL
      AND scope.cutover_adoption_rpc IS NOT NULL
      AND scope.reservation_table IS NOT NULL AND scope.process_setting_table IS NOT NULL
      AND scope.post_rpc_definition LIKE '%public.post_pos_sale(%'
      AND scope.public_post_definition LIKE '%private.post_pos_sale_before_schedule_core(%'
      AND scope.retail_identity_definition LIKE '%BACKOFFICE_CUTOVER%'
      AND scope.runtime_shape LIKE '%LEGACY_POSTED%'
      AND scope.runtime_shape LIKE '%document_status = ''POSTED''%'
      AND scope.fulfillment_shape LIKE '%fulfillment_mode%'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN scope.dependency_rows=6 AND scope.post_rpc IS NOT NULL
      AND scope.cutover_adoption_rpc IS NOT NULL
      AND scope.reservation_table IS NOT NULL AND scope.process_setting_table IS NOT NULL
      AND scope.post_rpc_definition LIKE '%public.post_pos_sale(%'
      AND scope.public_post_definition LIKE '%private.post_pos_sale_before_schedule_core(%'
      AND scope.retail_identity_definition LIKE '%BACKOFFICE_CUTOVER%'
      AND scope.runtime_shape LIKE '%LEGACY_POSTED%'
      AND scope.runtime_shape LIKE '%document_status = ''POSTED''%'
      AND scope.fulfillment_shape LIKE '%fulfillment_mode%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('dependencyRows',scope.dependency_rows,
      'postRpc',scope.post_rpc::text,
      'cutoverAdoptionRpc',scope.cutover_adoption_rpc::text,
      'reservationTable',scope.reservation_table::text,
      'processSettingTable',scope.process_setting_table::text,
      'postRpcCallsPublicPost',scope.post_rpc_definition LIKE '%public.post_pos_sale(%',
      'publicPostCallsScheduledCore',scope.public_post_definition LIKE '%private.post_pos_sale_before_schedule_core(%',
      'runtimeShape',scope.runtime_shape,
      'fulfillmentShape',scope.fulfillment_shape) FROM scope
  UNION ALL
  SELECT 25,'pos_retail_direct_post_cutover_compatibility',
    CASE WHEN invalid_identity_rows=0 AND adopted_without_snapshot_rows=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    invalid_identity_rows+adopted_without_snapshot_rows,
    jsonb_build_object('rows',rows,'detachedRows',detached_rows,
      'adoptedRows',adopted_rows,'invalidIdentityRows',invalid_identity_rows,
      'adoptedWithoutSnapshotRows',adopted_without_snapshot_rows,
      'meaning','Detached cutover Drafts stay detached; only adopted preserved Drafts may post')
    FROM cutover_inventory
  UNION ALL
  SELECT 30,'pos_retail_direct_post_installation_state',
    CASE WHEN (scope.target_ledger_rows=0 AND scope.bridge_trigger_rows=0
        AND scope.bridge_function IS NULL)
      OR (scope.target_ledger_rows=1 AND scope.bridge_trigger_rows=1
        AND scope.bridge_function IS NOT NULL) THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (scope.target_ledger_rows=0 AND scope.bridge_trigger_rows=0
        AND scope.bridge_function IS NULL)
      OR (scope.target_ledger_rows=1 AND scope.bridge_trigger_rows=1
        AND scope.bridge_function IS NOT NULL) THEN 0 ELSE 1 END,
    jsonb_build_object('state',CASE
      WHEN scope.target_ledger_rows=0 AND scope.bridge_trigger_rows=0
        AND scope.bridge_function IS NULL THEN 'NOT_INSTALLED'
      WHEN scope.target_ledger_rows=1 AND scope.bridge_trigger_rows=1
        AND scope.bridge_function IS NOT NULL THEN 'INSTALLED_CONSISTENT'
      ELSE 'PARTIAL_INCONSISTENT' END,'ledgerRows',scope.target_ledger_rows,
      'triggerRows',scope.bridge_trigger_rows,'function',scope.bridge_function::text)
    FROM scope
  UNION ALL
  SELECT 40,'pos_retail_direct_post_exact_failed_draft',
    CASE WHEN (SELECT count(*) FROM exact_draft)=1
      AND (SELECT document_status FROM exact_draft)='DRAFT'
      AND (SELECT order_runtime_status FROM exact_draft) IN('DRAFT_INPUT','SCHEDULED')
      AND (SELECT fulfillment_mode FROM exact_draft)='PICKUP'
      AND COALESCE((SELECT sj_required FROM exact_draft),false)=false
      AND (SELECT sales_origin FROM exact_draft)='POS'
      AND (SELECT sales_process_mode FROM exact_draft)='RETAIL_CONFIRM_INVOICE'
      AND (SELECT reservation_version FROM exact_draft)=0
      AND (SELECT confirmed_at FROM exact_draft) IS NULL
      AND (SELECT confirmed_by FROM exact_draft) IS NULL
      AND (SELECT confirmation_idempotency_key FROM exact_draft) IS NULL
      AND (SELECT session_status FROM exact_draft)='OPEN'
      AND (SELECT payment_rows+movement_rows+event_rows+invoice_rows+delivery_rows
        +reservation_rows FROM exact_draft)=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (SELECT count(*) FROM exact_draft)=1
      AND (SELECT document_status FROM exact_draft)='DRAFT'
      AND (SELECT order_runtime_status FROM exact_draft) IN('DRAFT_INPUT','SCHEDULED')
      AND (SELECT fulfillment_mode FROM exact_draft)='PICKUP'
      AND COALESCE((SELECT sj_required FROM exact_draft),false)=false
      AND (SELECT sales_origin FROM exact_draft)='POS'
      AND (SELECT sales_process_mode FROM exact_draft)='RETAIL_CONFIRM_INVOICE'
      AND (SELECT reservation_version FROM exact_draft)=0
      AND (SELECT confirmed_at FROM exact_draft) IS NULL
      AND (SELECT confirmed_by FROM exact_draft) IS NULL
      AND (SELECT confirmation_idempotency_key FROM exact_draft) IS NULL
      AND (SELECT session_status FROM exact_draft)='OPEN'
      AND (SELECT payment_rows+movement_rows+event_rows+invoice_rows+delivery_rows
        +reservation_rows FROM exact_draft)=0
      THEN 0 ELSE 1 END,
    COALESCE((SELECT to_jsonb(exact_draft) FROM exact_draft),'{}'::jsonb)
  UNION ALL
  SELECT 50,'pos_retail_direct_post_runtime_boundary',
    CASE WHEN queue_rows=0 AND offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    queue_rows+offline_rows,
    jsonb_build_object('activeFinanceQueue',queue_rows,
      'nonterminalOffline',offline_rows)
  FROM (SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))::int queue_rows,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))::int offline_rows) runtime
  UNION ALL
  SELECT 60,'pos_retail_direct_post_backoffice_boundary','INFO',0,
    jsonb_build_object('untouched',jsonb_build_array('backoffice_sales_orders',
      'confirm_backoffice_sales_order','Backoffice fulfillment and invoicing'),
      'retainedCompatibility','Already-adopted BACKOFFICE_CUTOVER Retail Drafts',
      'rule','Bridge may only transition direct POS or adopted cutover Retail Draft rows')
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY seq;

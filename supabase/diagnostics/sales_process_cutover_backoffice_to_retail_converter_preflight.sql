-- Cutover Step 4C/6: one-result SELECT-only preflight for the trusted
-- Backoffice -> Retail converter kernel. Isolated Development only.
-- This file performs no write and must be run in full.
WITH
required_versions(version) AS (VALUES
  ('20260909162000'::text),('20260909163000'),('20260910110000'),
  ('20260910120000'),('20260910130000'),('20260910140000'),
  ('20260910150000'),('20260910151000'),('20260910152000'),
  ('20260910153000'),('20260911100000')
),
dependency_state AS (
  SELECT count(ledger.version)::bigint present,
    COALESCE(jsonb_agg(required.version ORDER BY required.version)
      FILTER(WHERE ledger.version IS NULL),'[]'::jsonb) missing
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger USING(version)
),
required_relations(relation_name) AS (VALUES
  ('backoffice_sales_orders'::text),('backoffice_sales_order_lines'),
  ('backoffice_sales_reservations'),('backoffice_sales_reservation_lines'),
  ('backoffice_sales_delivery_orders'),('backoffice_sales_delivery_order_lines'),
  ('backoffice_sales_invoices'),('backoffice_sales_invoice_receivable_schedules'),
  ('sales_headers'),('sales_details'),('sale_stock_requirements'),
  ('sales_stock_reservations'),('sales_stock_reservation_lines'),
  ('sales_invoice_snapshots'),('sales_delivery_documents'),
  ('sales_process_cutover_plans'),('sales_process_cutover_items'),
  ('finance_posting_queue_runs'),('pos_offline_sale_submissions')
),
relation_state AS (
  SELECT count(actual.table_name)::bigint present,
    COALESCE(jsonb_agg(required.relation_name ORDER BY required.relation_name)
      FILTER(WHERE actual.table_name IS NULL),'[]'::jsonb) missing
  FROM required_relations required
  LEFT JOIN information_schema.tables actual
    ON actual.table_schema='public' AND actual.table_name=required.relation_name
),
required_columns(table_name,column_name) AS (VALUES
  ('backoffice_sales_orders'::text,'status'::text),
  ('backoffice_sales_orders','fulfillment_status'),
  ('backoffice_sales_orders','order_date'),
  ('backoffice_sales_orders','planned_delivery_date'),
  ('backoffice_sales_orders','is_tempo'),
  ('backoffice_sales_orders','due_date'),
  ('backoffice_sales_orders','payment_term_id'),
  ('backoffice_sales_orders','delivery_fee_amount'),
  ('backoffice_sales_orders','master_version'),
  ('backoffice_sales_order_lines','product_id'),
  ('backoffice_sales_order_lines','uom_id'),
  ('backoffice_sales_order_lines','ordered_qty'),
  ('backoffice_sales_order_lines','ordered_base_qty'),
  ('backoffice_sales_order_lines','canonical_unit_price'),
  ('backoffice_sales_order_lines','pricing_snapshot'),
  ('backoffice_sales_reservations','status'),
  ('backoffice_sales_reservation_lines','stock_uom_id'),
  ('backoffice_sales_reservation_lines','quantity_uom'),
  ('backoffice_sales_reservation_lines','factor_to_base'),
  ('backoffice_sales_reservation_lines','shortage_base_qty'),
  ('backoffice_sales_delivery_orders','status'),
  ('sales_headers','sales_origin'),
  ('sales_headers','sales_process_mode'),
  ('sales_headers','order_runtime_status'),
  ('sales_headers','order_timing_mode'),
  ('sales_headers','planned_order_date'),
  ('sales_headers','session_id'),
  ('sales_headers','pos_id'),
  ('sales_headers','created_session_id')
),
column_state AS (
  SELECT count(actual.column_name)::bigint present,
    COALESCE(jsonb_agg(jsonb_build_object('table',required.table_name,
      'column',required.column_name) ORDER BY required.table_name,required.column_name)
      FILTER(WHERE actual.column_name IS NULL),'[]'::jsonb) missing
  FROM required_columns required
  LEFT JOIN information_schema.columns actual
    ON actual.table_schema='public' AND actual.table_name=required.table_name
   AND actual.column_name=required.column_name
),
required_routines(signature) AS (VALUES
  ('private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)'::text),
  ('private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamp with time zone)'),
  ('private.ensure_confirmed_order_invoice_identity(uuid,uuid)'),
  ('private.ensure_confirmed_order_documents(uuid,uuid)'),
  ('private.backoffice_sales_order_snapshot(uuid,uuid)'),
  ('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)')
),
routine_state AS (
  SELECT count(to_regprocedure(required.signature))::bigint present,
    COALESCE(jsonb_agg(required.signature ORDER BY required.signature)
      FILTER(WHERE to_regprocedure(required.signature) IS NULL),'[]'::jsonb) missing
  FROM required_routines required
),
open_documents AS MATERIALIZED (
  SELECT document.*,company.timezone,
    (clock_timestamp() AT TIME ZONE company.timezone)::date company_today
  FROM public.backoffice_sales_orders document
  JOIN public.companies company ON company.id=document.company_id
  WHERE document.sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    AND document.status IN('DRAFT','SENT','CONFIRMED')
    AND document.fulfillment_status NOT IN('COMPLETED','CANCELED')
),
line_mapping AS MATERIALIZED (
  SELECT document.company_id,document.id document_id,
    line.id line_id,count(CASE WHEN product.id IS NOT NULL AND uom.id IS NOT NULL
      THEN product_uom.id END)::bigint mapping_count
  FROM open_documents document
  JOIN public.backoffice_sales_order_lines line
    ON line.company_id=document.company_id AND line.sales_order_id=document.id
  LEFT JOIN public.product_uoms product_uom
    ON product_uom.company_id=line.company_id
   AND product_uom.product_id=line.product_id AND product_uom.uom_id=line.uom_id
   AND product_uom.is_active AND product_uom.sales_allowed
  LEFT JOIN public.products product ON product.company_id=product_uom.company_id
   AND product.id=product_uom.product_id AND product.is_active
  LEFT JOIN public.uoms uom ON uom.company_id=product_uom.company_id
   AND uom.id=product_uom.uom_id AND uom.is_active
  GROUP BY document.company_id,document.id,line.id
),
checks AS (
  SELECT 'preflight_revision'::text check_name,'INFO'::text status,0::bigint violation_rows,
    jsonb_build_object('revision','STEP_4C_V1_ONE_RESULT',
      'executionRule','Run the entire file; do not run selected text',
      'writes',false) details
  UNION ALL SELECT 'step_4c_dependency_ledger',
    CASE WHEN present=11 THEN 'PASS' ELSE 'BLOCKER' END,(11-present)::bigint,
    jsonb_build_object('expected',11,'present',present,'missing',missing)
  FROM dependency_state
  UNION ALL SELECT 'step_4c_relation_contract',
    CASE WHEN present=19 THEN 'PASS' ELSE 'BLOCKER' END,(19-present)::bigint,
    jsonb_build_object('expected',19,'present',present,'missing',missing)
  FROM relation_state
  UNION ALL SELECT 'step_4c_column_contract',
    CASE WHEN present=29 THEN 'PASS' ELSE 'BLOCKER' END,(29-present)::bigint,
    jsonb_build_object('expected',29,'present',present,'missing',missing)
  FROM column_state
  UNION ALL SELECT 'step_4c_routine_contract',
    CASE WHEN present=6 THEN 'PASS' ELSE 'BLOCKER' END,(6-present)::bigint,
    jsonb_build_object('expected',6,'present',present,'missing',missing)
  FROM routine_state
  UNION ALL SELECT 'step_4c_reverse_converter_collision',
    CASE WHEN to_regprocedure('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)') IS NULL
      THEN 'SETUP' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)') IS NULL
      THEN 1 ELSE 1 END,
    jsonb_build_object('required','Function must be absent before migration',
      'existing',to_regprocedure('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)') IS NOT NULL)
  UNION ALL SELECT 'step_4c_public_apply_boundary',
    CASE WHEN to_regprocedure('public.apply_sales_process_cutover_plan(uuid,bigint,uuid)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('public.apply_sales_process_cutover_plan(uuid,bigint,uuid)') IS NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('publicApplyAbsent',
      to_regprocedure('public.apply_sales_process_cutover_plan(uuid,bigint,uuid)') IS NULL)
  UNION ALL SELECT 'step_4c_open_plan_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('openPlans',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL SELECT 'step_4c_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL SELECT 'step_4c_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissions',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL SELECT 'step_4c_open_document_inventory','INFO',0::bigint,
    jsonb_build_object('documents',count(*),
      'draft',count(*) FILTER(WHERE status IN('DRAFT','SENT')),
      'confirmedCurrent',count(*) FILTER(WHERE status='CONFIRMED' AND order_date<=company_today),
      'confirmedFutureTempo',count(*) FILTER(WHERE status='CONFIRMED' AND is_tempo AND order_date>company_today),
      'futureNonTempo',count(*) FILTER(WHERE NOT is_tempo AND order_date>company_today))
  FROM open_documents
  UNION ALL SELECT 'step_4c_line_presence',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'INFO' END,0::bigint,
    jsonb_build_object('documentsWithoutLines',count(*),
      'rule','Open Backoffice source must have at least one line')
  FROM open_documents document WHERE NOT EXISTS(SELECT 1
    FROM public.backoffice_sales_order_lines line
    WHERE line.company_id=document.company_id AND line.sales_order_id=document.id)
  UNION ALL SELECT 'step_4c_product_uom_mapping',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'INFO' END,0::bigint,
    jsonb_build_object('invalidLines',count(*),
      'rule','Exactly one active sales Product-UOM must match source Product and UOM')
  FROM line_mapping WHERE mapping_count<>1
  UNION ALL SELECT 'step_4c_active_master_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'INFO' END,0::bigint,
    jsonb_build_object('invalidDocuments',count(*))
  FROM open_documents document
  WHERE NOT EXISTS(SELECT 1 FROM public.stores store
      WHERE store.company_id=document.company_id AND store.id=document.store_id
        AND store.status='ACTIVE')
    OR NOT EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=document.company_id AND customer.id=document.customer_id
        AND customer.is_active)
    OR NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=document.company_id AND warehouse.id=document.warehouse_id
        AND warehouse.is_active AND warehouse.is_sale_source)
  UNION ALL SELECT 'step_4c_confirmed_fulfillment_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'INFO' END,0::bigint,
    jsonb_build_object('invalidDocuments',count(*),
      'rule','Confirmed source has one untouched Reservation and one unshipped initial DO')
  FROM open_documents document
  WHERE document.status='CONFIRMED' AND (
    (SELECT count(*) FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=document.company_id
        AND reservation.sales_order_id=document.id
        AND reservation.status IN('OPEN','PARTIALLY_ALLOCATED','ALLOCATED'))<>1
    OR (SELECT count(*) FROM public.backoffice_sales_delivery_orders delivery
      WHERE delivery.company_id=document.company_id
        AND delivery.sales_order_id=document.id AND delivery.delivery_kind='INITIAL'
        AND delivery.status IN('PREPARING','READY')
        AND delivery.total_shipped_base_qty=0
        AND delivery.total_received_base_qty=0)<>1)
  UNION ALL SELECT 'step_4c_future_confirmed_tempo_policy','INFO',0::bigint,
    jsonb_build_object('documents',count(*),
      'policy','Convert to Retail Scheduled Draft; release Backoffice Reservation/DO; reconfirm in Retail on active date')
  FROM open_documents
  WHERE status='CONFIRMED' AND is_tempo AND order_date>company_today
  UNION ALL SELECT 'step_4c_future_non_tempo_inventory','INFO',0::bigint,
    jsonb_build_object('documents',count(*),
      'rule','Future non-TEMPO remains grandfathered and is not converted')
  FROM open_documents WHERE NOT is_tempo AND order_date>company_today
  UNION ALL SELECT 'step_4c_future_non_tempo_preview_contract',
    CASE WHEN pg_get_functiondef(
      'private.get_sales_process_cutover_preview_core(uuid,text)'::regprocedure)
      ~ 'order_date[[:space:]]*>[[:space:]]*\(clock_timestamp\(\)[[:space:]]+AT[[:space:]]+TIME[[:space:]]+ZONE'
      THEN 'PASS' ELSE 'SETUP' END,
    CASE WHEN pg_get_functiondef(
      'private.get_sales_process_cutover_preview_core(uuid,text)'::regprocedure)
      ~ 'order_date[[:space:]]*>[[:space:]]*\(clock_timestamp\(\)[[:space:]]+AT[[:space:]]+TIME[[:space:]]+ZONE'
      THEN 0 ELSE 1 END,
    jsonb_build_object('required',
      'Preview must classify future non-TEMPO Backoffice documents BLOCKED before Apply')
  UNION ALL SELECT 'step_4c_multi_installment_classifier_contract',
    CASE WHEN result->>'decision'='BLOCKED'
      AND result->'blockerCodes' ? 'MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN result->>'decision'='BLOCKED'
      AND result->'blockerCodes' ? 'MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE'
      THEN 0 ELSE 1 END,
    jsonb_build_object('result',result)
  FROM (SELECT private.classify_sales_process_conversion_candidate(
    'BACKOFFICE_DELIVERED_QTY_INVOICE','RETAIL_CONFIRM_INVOICE',false,
    false,false,false,false,false,false,false,true) result) classifier
  UNION ALL SELECT 'step_4c_multi_installment_inventory','INFO',0::bigint,
    jsonb_build_object('documents',count(*),
      'rule','More than one Payment Term installment remains in Backoffice')
  FROM open_documents document
  WHERE document.payment_term_id IS NOT NULL
    AND (SELECT count(*) FROM public.backoffice_sales_payment_term_lines term_line
      WHERE term_line.company_id=document.company_id
        AND term_line.payment_term_id=document.payment_term_id)>1
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'SETUP' THEN 1
  WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

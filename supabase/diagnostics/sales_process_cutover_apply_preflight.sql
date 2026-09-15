-- Step 1E/6: one-result, SELECT-only readiness audit before cutover Apply.
-- Run only on isolated Development. This statement performs no write.

WITH
revision_check AS (
  SELECT 'preflight_revision'::text check_name,'INFO'::text status,
    0::bigint violation_rows,
    jsonb_build_object('revision','STEP_1E_V2_ONE_RESULT',
      'executionRule','Run the entire file; do not run selected text') details
),
dependency_versions(version) AS (
  VALUES ('20260908100000'::text),('20260908110000'),('20260909145000'),
    ('20260909162000'),('20260909163000'),('20260910110000'),
    ('20260910120000'),('20260910130000')
),
dependency_state AS (
  SELECT count(ledger.version)::bigint present
  FROM dependency_versions expected
  LEFT JOIN private.kgs_schema_migrations ledger USING(version)
),
required_relations(relation_name) AS (
  VALUES ('company_sales_process_settings'::text),
    ('company_sales_process_mode_history'),('sales_process_cutover_plans'),
    ('sales_process_cutover_items'),('sales_process_cutover_audit'),
    ('sales_headers'),('sales_details'),('sale_master_audit'),
    ('sales_stock_reservations'),('sales_stock_reservation_lines'),
    ('sales_order_procurement_demand_lines'),('backoffice_sales_orders'),
    ('backoffice_sales_order_lines'),('backoffice_sales_order_audit'),
    ('backoffice_sales_reservations'),('backoffice_sales_reservation_lines'),
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
required_columns(table_name,column_name) AS (
  VALUES
    ('sales_process_cutover_items'::text,'source_document_id'::text),
    ('sales_process_cutover_items','source_document_no'),
    ('sales_process_cutover_items','source_master_version'),
    ('sales_process_cutover_items','decision'),
    ('sales_process_cutover_items','item_status'),
    ('sales_process_cutover_items','target_document_id'),
    ('sales_process_cutover_items','target_document_type'),
    ('sales_process_cutover_items','target_document_no'),
    ('sales_headers','sales_origin'),('sales_headers','sales_process_mode'),
    ('sales_headers','order_runtime_status'),('sales_headers','master_version'),
    ('sales_headers','planned_order_date'),('sales_headers','order_timing_mode'),
    ('sales_headers','sales_warehouse_id'),('sales_headers','store_id'),
    ('sales_headers','customer_id'),('sales_headers','is_tempo'),
    ('sales_headers','due_date'),('sales_headers','canceled_at'),
    ('sales_headers','canceled_by'),('sales_headers','cancel_reason'),
    ('sales_details','sales_id'),('sales_details','product_id'),
    ('sales_details','sale_uom_id'),('sales_details','quantity_base'),
    ('sales_details','uom_factor_to_base_snapshot'),
    ('backoffice_sales_orders','sales_process_mode'),
    ('backoffice_sales_orders','fulfillment_status'),
    ('backoffice_sales_orders','master_version'),
    ('backoffice_sales_orders','store_id'),
    ('backoffice_sales_orders','warehouse_id'),
    ('backoffice_sales_orders','customer_id'),
    ('backoffice_sales_orders','order_date'),
    ('backoffice_sales_orders','planned_delivery_date'),
    ('backoffice_sales_orders','canceled_at'),
    ('backoffice_sales_orders','canceled_by'),
    ('backoffice_sales_orders','cancel_reason'),
    ('backoffice_sales_order_lines','sales_order_id'),
    ('backoffice_sales_order_lines','product_id'),
    ('backoffice_sales_order_lines','uom_id'),
    ('backoffice_sales_order_lines','ordered_qty'),
    ('backoffice_sales_order_lines','ordered_base_qty'),
    ('backoffice_sales_order_lines','canonical_unit_price')
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
routine_state AS (
  SELECT count(routine_oid)::bigint present FROM (VALUES
    (to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)')),
    (to_regprocedure('private.get_sales_process_cutover_plan_core(uuid,uuid)')),
    (to_regprocedure('private.create_sales_process_cutover_plan_core(uuid,uuid,text,timestamptz,bigint,uuid,text)')),
    (to_regprocedure('private.refresh_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,bigint,uuid)')),
    (to_regprocedure('private.cancel_sales_process_cutover_plan_core(uuid,uuid,uuid,bigint,uuid,text)')),
    (to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)')),
    (to_regprocedure('private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)'))
  ) required(routine_oid)
),
classifier_state AS (
  SELECT private.classify_sales_process_conversion_candidate(
      'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
      false,false,false,false,false,true,false) pending_revision,
    private.classify_sales_process_conversion_candidate(
      'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
      false,false,false,false,false,false,true) open_procurement
),
previews AS MATERIALIZED (
  SELECT setting.company_id,setting.active_mode,
    CASE WHEN setting.active_mode='RETAIL_CONFIRM_INVOICE'
      THEN 'BACKOFFICE_DELIVERED_QTY_INVOICE'
      ELSE 'RETAIL_CONFIRM_INVOICE' END target_mode,
    private.get_sales_process_cutover_preview_core(setting.company_id,
      CASE WHEN setting.active_mode='RETAIL_CONFIRM_INVOICE'
        THEN 'BACKOFFICE_DELIVERED_QTY_INVOICE'
        ELSE 'RETAIL_CONFIRM_INVOICE' END) preview
  FROM public.company_sales_process_settings setting
),
candidates AS MATERIALIZED (
  SELECT preview.company_id,preview.active_mode,preview.target_mode,
    candidate.value candidate
  FROM previews preview
  CROSS JOIN LATERAL jsonb_array_elements(preview.preview->'candidates') candidate(value)
),
facts AS MATERIALIZED (
  SELECT company_id,active_mode,target_mode,
    candidate->>'sourceDocumentType' source_type,
    (candidate->>'sourceDocumentId')::uuid source_id,
    candidate->>'sourceDocumentNo' source_no,
    candidate->>'sourceStatus' source_status,
    candidate->>'decision' decision,
    COALESCE((candidate->'facts'->>'hasOpenProcurement')::boolean,false) has_procurement,
    candidate->'facts' source_facts
  FROM candidates
),
catalog_checks AS (
  SELECT 'cutover_apply_dependency_ledger'::text check_name,
    CASE WHEN present=8 THEN 'PASS' ELSE 'BLOCKER' END status,
    (8-present)::bigint violation_rows,
    jsonb_build_object('expected',8,'present',present) details
  FROM dependency_state
  UNION ALL
  SELECT 'cutover_apply_relation_contract',
    CASE WHEN present=18 THEN 'PASS' ELSE 'BLOCKER' END,
    (18-present)::bigint,jsonb_build_object('expected',18,'present',present,'missing',missing)
  FROM relation_state
  UNION ALL
  SELECT 'cutover_apply_column_contract',
    CASE WHEN present=44 THEN 'PASS' ELSE 'BLOCKER' END,
    (44-present)::bigint,jsonb_build_object('expected',44,'present',present,'missing',missing)
  FROM column_state
  UNION ALL
  SELECT 'cutover_apply_routine_contract',
    CASE WHEN present=7 THEN 'PASS' ELSE 'BLOCKER' END,
    (7-present)::bigint,jsonb_build_object('expected',7,'present',present)
  FROM routine_state
  UNION ALL
  SELECT 'cutover_apply_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('collisionRows',count(*),
      'routines',COALESCE(jsonb_agg(namespace.nspname||'.'||procedure.proname
        ORDER BY namespace.nspname,procedure.proname),'[]'::jsonb))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname='private' AND procedure.proname IN(
      'apply_sales_process_cutover_plan_core','convert_retail_sale_to_backoffice_order',
      'convert_backoffice_order_to_retail_sale'))
    OR (namespace.nspname='public' AND procedure.proname='apply_sales_process_cutover_plan')
  UNION ALL
  SELECT 'cutover_apply_lineage_column_contract',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,abs(3-count(*))::bigint,
    jsonb_build_object('expected',3,'present',count(*),
      'columns',COALESCE(jsonb_agg(column_name ORDER BY column_name),'[]'::jsonb))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sales_process_cutover_items'
    AND column_name IN('target_document_id','target_document_type','target_document_no')
  UNION ALL
  SELECT 'preflight_environment_identity','INFO',0::bigint,
    jsonb_build_object('database',current_database(),'databaseUser',current_user,
      'serverAddress',inet_server_addr()::text,'serverPort',inet_server_port())
),
runtime_checks AS (
  SELECT 'open_cutover_plan_before_classifier_upgrade'::text check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,count(*)::bigint violation_rows,
    jsonb_build_object('openPlans',count(*),
      'rule','Cancel and recreate after eligibility classifier upgrade') details
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'prior_cutover_apply_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('finalOrLinkedRows',count(*))
  FROM (
    SELECT plan.id::text FROM public.sales_process_cutover_plans plan WHERE plan.status='APPLIED'
    UNION ALL
    SELECT item.id::text FROM public.sales_process_cutover_items item
      WHERE item.item_status='APPLIED' OR item.target_document_id IS NOT NULL
    UNION ALL
    SELECT audit.id::text FROM public.sales_process_cutover_audit audit
      WHERE audit.action IN('APPLY_ITEM','APPLY_MODE')
  ) applied
  UNION ALL
  SELECT 'active_finance_queue_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'company_sales_process_setting_coverage',
    CASE WHEN company_rows=setting_rows THEN 'PASS' ELSE 'BLOCKER' END,
    abs(company_rows-setting_rows)::bigint,
    jsonb_build_object('companies',company_rows,'settings',setting_rows)
  FROM (SELECT (SELECT count(*) FROM public.companies) company_rows,
    (SELECT count(*) FROM public.company_sales_process_settings) setting_rows) inventory
  UNION ALL
  SELECT 'pending_revision_classifier_contract',
    CASE WHEN pending_revision->>'decision'='BLOCKED'
      AND (pending_revision->'blockerCodes') ? 'PENDING_REVISION_MUST_RESOLVE'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN pending_revision->>'decision'='BLOCKED'
      AND (pending_revision->'blockerCodes') ? 'PENDING_REVISION_MUST_RESOLVE'
      THEN 0 ELSE 1 END,
    jsonb_build_object('result',pending_revision)
  FROM classifier_state
  UNION ALL
  SELECT 'open_procurement_classifier_upgrade',
    CASE WHEN open_procurement->>'decision'='BLOCKED'
      AND (open_procurement->'blockerCodes') ? 'OPEN_PROCUREMENT_MUST_FINISH'
      THEN 'PASS' ELSE 'SETUP' END,
    CASE WHEN open_procurement->>'decision'='BLOCKED'
      AND (open_procurement->'blockerCodes') ? 'OPEN_PROCUREMENT_MUST_FINISH'
      THEN 0 ELSE 1 END,
    jsonb_build_object('currentResult',open_procurement,
      'required','BLOCKED + OPEN_PROCUREMENT_MUST_FINISH')
  FROM classifier_state
),
candidate_checks AS (
  SELECT 'cutover_candidate_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,
    jsonb_build_object('companies',count(DISTINCT company_id),'candidateRows',count(*),
      'convertible',count(*) FILTER(WHERE decision='CONVERT'),
      'blocked',count(*) FILTER(WHERE decision='BLOCKED'),
      'keepSource',count(*) FILTER(WHERE decision='KEEP_SOURCE'),
      'retail',count(*) FILTER(WHERE source_type='RETAIL_SALE'),
      'backoffice',count(*) FILTER(WHERE source_type='BACKOFFICE_SALES_ORDER')) details
  FROM facts
  UNION ALL
  SELECT 'open_procurement_candidate_reclassification',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,count(*)::bigint,
    jsonb_build_object('rows',count(*),'documents',COALESCE(jsonb_agg(
      jsonb_build_object('companyId',company_id,'documentNo',source_no,'decision',decision)
      ORDER BY source_no),'[]'::jsonb),'required','BLOCKED/grandfathered')
  FROM facts WHERE has_procurement AND decision<>'BLOCKED'
  UNION ALL
  SELECT 'office_future_non_tempo_reclassification',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,count(*)::bigint,
    jsonb_build_object('rows',count(*),'documents',COALESCE(jsonb_agg(
      jsonb_build_object('companyId',document.company_id,
        'documentNo',COALESCE(document.order_no,document.quotation_no),
        'orderDate',document.order_date) ORDER BY document.order_date,
        COALESCE(document.order_no,document.quotation_no)),'[]'::jsonb),
      'required','BLOCKED/grandfathered')
  FROM public.backoffice_sales_orders document
  JOIN public.companies company ON company.id=document.company_id
  JOIN public.company_sales_process_settings setting ON setting.company_id=document.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE document.sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    AND document.status IN('DRAFT','SENT','CONFIRMED')
    AND document.fulfillment_status NOT IN('COMPLETED','CANCELED')
    AND NOT document.is_tempo
    AND document.order_date>(clock_timestamp() AT TIME ZONE company.timezone)::date
  UNION ALL
  SELECT 'convertible_source_without_lines',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,count(*)::bigint,
    jsonb_build_object('rows',count(*),'documents',COALESCE(jsonb_agg(
      jsonb_build_object('companyId',fact.company_id,'sourceType',fact.source_type,
        'documentNo',fact.source_no) ORDER BY fact.source_type,fact.source_no),'[]'::jsonb),
      'required','BLOCKED; empty documents are not converted')
  FROM facts fact
  WHERE fact.decision='CONVERT' AND NOT EXISTS(
    SELECT 1 FROM public.sales_details line
      WHERE fact.source_type='RETAIL_SALE' AND line.company_id=fact.company_id
        AND line.sales_id=fact.source_id
    UNION ALL
    SELECT 1 FROM public.backoffice_sales_order_lines line
      WHERE fact.source_type='BACKOFFICE_SALES_ORDER'
        AND line.company_id=fact.company_id AND line.sales_order_id=fact.source_id)
  UNION ALL
  SELECT 'retail_convertible_line_mapping',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,count(*)::bigint,
    jsonb_build_object('invalidLines',count(*),
      'required','Positive Qty/Base factor and canonical Product-UOM')
  FROM facts fact
  JOIN public.sales_details line ON fact.source_type='RETAIL_SALE'
    AND line.company_id=fact.company_id AND line.sales_id=fact.source_id
  LEFT JOIN public.product_uoms product_uom ON product_uom.company_id=line.company_id
    AND product_uom.id=line.product_uom_id AND product_uom.product_id=line.product_id
  LEFT JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id
  LEFT JOIN public.uoms uom ON uom.company_id=product_uom.company_id
    AND uom.id=product_uom.uom_id
  WHERE fact.decision='CONVERT' AND (line.qty<=0 OR line.quantity_base<=0
    OR line.uom_factor_to_base_snapshot<=0 OR product_uom.id IS NULL
    OR NOT product_uom.is_active OR NOT product_uom.sales_allowed
    OR NOT product.is_active OR NOT uom.is_active)
  UNION ALL
  SELECT 'backoffice_convertible_line_mapping',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,count(*)::bigint,
    jsonb_build_object('invalidLines',count(*),
      'required','Exactly one canonical Product-UOM mapping')
  FROM facts fact
  JOIN public.backoffice_sales_order_lines line ON fact.source_type='BACKOFFICE_SALES_ORDER'
    AND line.company_id=fact.company_id AND line.sales_order_id=fact.source_id
  LEFT JOIN LATERAL (SELECT count(*) mapping_count FROM public.product_uoms product_uom
    WHERE product_uom.company_id=line.company_id AND product_uom.product_id=line.product_id
      AND product_uom.uom_id=line.uom_id) mapping ON true
  WHERE fact.decision='CONVERT' AND (line.ordered_qty<=0 OR line.ordered_base_qty<=0
    OR line.canonical_unit_price<0 OR mapping.mapping_count<>1)
  UNION ALL
  SELECT 'convertible_reservation_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,count(*)::bigint,
    jsonb_build_object('invalidDocuments',count(*),
      'required','Confirmed/reserved source has exactly one untouched reservation')
  FROM facts fact WHERE fact.decision='CONVERT' AND (
    (fact.source_type='RETAIL_SALE' AND fact.source_status IN('CONFIRMED','RESERVED')
      AND (SELECT count(*) FROM public.sales_stock_reservations reservation
        WHERE reservation.company_id=fact.company_id AND reservation.sales_id=fact.source_id
          AND reservation.status='OPEN')<>1)
    OR (fact.source_type='BACKOFFICE_SALES_ORDER'
      AND COALESCE(fact.source_facts->>'documentStatus','')='CONFIRMED'
      AND (SELECT count(*) FROM public.backoffice_sales_reservations reservation
        WHERE reservation.company_id=fact.company_id
          AND reservation.sales_order_id=fact.source_id
          AND reservation.status IN('OPEN','PARTIALLY_ALLOCATED','ALLOCATED'))<>1))
),
lineage_check AS (
  SELECT 'cutover_lineage_runtime_inventory_v2'::text check_name,'INFO'::text status,
    0::bigint violation_rows,
    jsonb_build_object('plans',(SELECT count(*) FROM public.sales_process_cutover_plans),
      'items',(SELECT count(*) FROM public.sales_process_cutover_items),
      'linkedItems',(SELECT count(*) FROM public.sales_process_cutover_items
        WHERE target_document_id IS NOT NULL),
      'applyAudits',(SELECT count(*) FROM public.sales_process_cutover_audit
        WHERE action IN('APPLY_ITEM','APPLY_MODE'))) details
),
all_checks AS (
  SELECT * FROM revision_check UNION ALL SELECT * FROM catalog_checks
  UNION ALL SELECT * FROM runtime_checks
  UNION ALL SELECT * FROM candidate_checks UNION ALL SELECT * FROM lineage_check
)
SELECT check_name,status,violation_rows,details FROM all_checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'SETUP' THEN 1
  WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

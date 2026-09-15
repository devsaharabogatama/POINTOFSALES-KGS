-- READ ONLY. Production discovery only; this file performs no DDL or DML.
-- Run only after the user explicitly opens the production-readiness audit.
-- The result is inventory evidence, not permission to migrate or deploy.
WITH base_relation_contract(name) AS (VALUES
  ('companies'),('stores'),('warehouses'),('products'),('product_uoms'),
  ('customers'),('sales_headers'),('sales_details'),('stock_movements'),
  ('financial_events'),('finance_posting_queue_runs'),
  ('pos_offline_sale_submissions'),('supplier_order_documents'),
  ('supplier_order_lines'),('goods_receipt_documents'),('goods_receipt_lines'),
  ('purchase_return_documents'),('supplier_invoice_documents'),
  ('supplier_payment_documents')
), expected_new_relations(name) AS (VALUES
  ('backoffice_sales_orders'),('backoffice_sales_order_lines'),
  ('backoffice_sales_reservations'),('backoffice_sales_delivery_orders'),
  ('backoffice_sales_invoices'),('backoffice_sales_invoice_lines'),
  ('sales_process_cutover_plans'),('sales_process_cutover_items'),
  ('company_purchase_replenishment_settings'),
  ('purchase_daily_batches'),
  ('purchase_daily_batch_lines'),
  ('purchase_daily_scheduler_runs')
), checks AS (
  SELECT 'environment_identity'::text check_name,'INFO'::text status,0::bigint violation_rows,
    jsonb_build_object('database',current_database(),'databaseUser',current_user,
      'serverAddress',inet_server_addr(),'serverPort',inet_server_port(),
      'capturedAt',clock_timestamp()) details
  UNION ALL
  SELECT 'application_migration_ledger','INFO',0,
    jsonb_build_object('candidateRows',count(*),'firstInstalled',min(version),
      'lastInstalled',max(version),'installedVersions',
      COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb))
  FROM private.kgs_schema_migrations
  WHERE version BETWEEN '20260908100000' AND '20260914180000'
  UNION ALL
  SELECT 'base_relation_contract',
    CASE WHEN count(table_info.table_name)=19 THEN 'PASS' ELSE 'BLOCKER' END,
    19-count(table_info.table_name),jsonb_build_object('expected',19,
      'present',count(table_info.table_name),'missing',
      COALESCE(jsonb_agg(contract.name ORDER BY contract.name)
        FILTER(WHERE table_info.table_name IS NULL),'[]'::jsonb))
  FROM base_relation_contract contract
  LEFT JOIN information_schema.tables table_info
    ON table_info.table_schema='public' AND table_info.table_name=contract.name
  UNION ALL
  SELECT 'candidate_object_inventory','INFO',0,
    jsonb_build_object('presentCount',count(table_info.table_name),'expectedAfterFullRollout',12,
      'present',COALESCE(jsonb_agg(contract.name ORDER BY contract.name)
        FILTER(WHERE table_info.table_name IS NOT NULL),'[]'::jsonb),
      'absent',COALESCE(jsonb_agg(contract.name ORDER BY contract.name)
        FILTER(WHERE table_info.table_name IS NULL),'[]'::jsonb))
  FROM expected_new_relations contract
  LEFT JOIN information_schema.tables table_info
    ON table_info.table_schema='public' AND table_info.table_name=contract.name
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'existing_transaction_inventory','INFO',0,jsonb_build_object(
    'salesHeaders',(SELECT count(*) FROM public.sales_headers),
    'salesDetails',(SELECT count(*) FROM public.sales_details),
    'stockMovements',(SELECT count(*) FROM public.stock_movements),
    'financialEvents',(SELECT count(*) FROM public.financial_events),
    'supplierOrders',(SELECT count(*) FROM public.supplier_order_documents),
    'goodsReceipts',(SELECT count(*) FROM public.goods_receipt_documents),
    'purchaseReturns',(SELECT count(*) FROM public.purchase_return_documents),
    'supplierInvoices',(SELECT count(*) FROM public.supplier_invoice_documents),
    'supplierPayments',(SELECT count(*) FROM public.supplier_payment_documents))
  UNION ALL
  SELECT 'open_supplier_order_inventory','INFO',0,jsonb_build_object(
    'confirmedOrPartial',count(*),
    'identityDigest',md5(COALESCE(string_agg(document.company_id::text||'|'||
      document.id::text||'|'||COALESCE(to_jsonb(document)->>'order_no','')||'|'||
      COALESCE(to_jsonb(document)->>'status',''),',' ORDER BY document.company_id,document.id),'')))
  FROM public.supplier_order_documents document
  WHERE to_jsonb(document)->>'status' IN('CONFIRMED','PARTIALLY_RECEIVED')
  UNION ALL
  SELECT 'generated_receipt_backfill_current_shape','INFO',0,jsonb_build_object(
    'candidatePoWarehousePairs',count(*),
    'identityDigest',md5(COALESCE(string_agg(candidate.company_id::text||'|'||
      candidate.id::text||'|'||candidate.destination_warehouse_id,','
      ORDER BY candidate.company_id,candidate.id,candidate.destination_warehouse_id),'')),
    'note','Exact post-checkpoint candidate set must be captured again immediately before 20260914180000')
  FROM (
    SELECT document.company_id,document.id,
      to_jsonb(line)->>'destination_warehouse_id' destination_warehouse_id
    FROM public.supplier_order_documents document
    JOIN public.supplier_order_lines line
      ON line.company_id=document.company_id
     AND (to_jsonb(line)->>'document_id')=document.id::text
    JOIN public.warehouses warehouse
      ON warehouse.company_id=line.company_id
     AND warehouse.id::text=(to_jsonb(line)->>'destination_warehouse_id')
    WHERE to_jsonb(document)->>'status' IN('CONFIRMED','PARTIALLY_RECEIVED')
      AND NULLIF(to_jsonb(line)->>'destination_warehouse_id','') IS NOT NULL
      AND COALESCE((to_jsonb(warehouse)->>'is_active')::boolean,false)
      AND COALESCE((to_jsonb(warehouse)->>'is_purchase_destination')::boolean,false)
      AND COALESCE(to_jsonb(warehouse)->>'warehouse_type','')<>'TRANSIT'
      AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
        WHERE receipt.company_id=document.company_id
          AND to_jsonb(receipt)->>'supplier_order_id'=document.id::text
          AND to_jsonb(receipt)->>'warehouse_id'=to_jsonb(line)->>'destination_warehouse_id'
          AND to_jsonb(receipt)->>'source_channel'='BACKOFFICE'
          AND to_jsonb(receipt)->>'status'='DRAFT')
    GROUP BY document.company_id,document.id,to_jsonb(line)->>'destination_warehouse_id'
  ) candidate
  UNION ALL
  SELECT 'scheduler_extension_inventory','INFO',0,
    jsonb_build_object('pgCronInstalled',EXISTS(
      SELECT 1 FROM pg_extension WHERE extname='pg_cron'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

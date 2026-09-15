-- Read-only preflight for Backoffice Delivery Dispatch -> dedicated Transit.
WITH checks AS (
  SELECT 'dispatch_to_transit_dependencies'::text check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260909150000')
      AND to_regprocedure('private.resolve_or_create_warehouse_transit(uuid,uuid,text,uuid)') IS NOT NULL
      AND to_regprocedure('private.save_stock_transfer_document(uuid,bigint,uuid,uuid,date,text,jsonb)') IS NOT NULL
      AND to_regprocedure('private.post_stock_transfer(uuid,bigint,uuid)') IS NOT NULL
      AND to_regprocedure('public.get_inventory_backoffice_delivery_orders(date,date)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('transitGate',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260909150000'),
      'transitResolver',to_regprocedure('private.resolve_or_create_warehouse_transit(uuid,uuid,text,uuid)') IS NOT NULL,
      'stockTransferSave',to_regprocedure('private.save_stock_transfer_document(uuid,bigint,uuid,uuid,date,text,jsonb)') IS NOT NULL,
      'stockTransferPost',to_regprocedure('private.post_stock_transfer(uuid,bigint,uuid)') IS NOT NULL,
      'deliveryReader',to_regprocedure('public.get_inventory_backoffice_delivery_orders(date,date)') IS NOT NULL) details
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*)) FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'stock_transfer_category_coverage',
    CASE WHEN count(*) FILTER(WHERE category_count<>1)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidCompanies',count(*) FILTER(WHERE category_count<>1),
      'details',COALESCE(jsonb_agg(jsonb_build_object('companyId',company_id,
        'categoryCount',category_count)) FILTER(WHERE category_count<>1),'[]'::jsonb))
  FROM (SELECT company.id company_id,count(category.id) category_count
    FROM public.companies company
    LEFT JOIN public.transaction_categories category ON category.company_id=company.id
      AND category.system_key='STOCK_TRANSFER' AND category.is_active
      AND category.is_system_default
    WHERE company.status='ACTIVE' GROUP BY company.id) coverage
), inventory AS (
  SELECT 'dispatch_to_transit_runtime_inventory'::text check_name,'INFO'::text status,
    jsonb_build_object('readyDeliveries',(SELECT count(*)
        FROM public.backoffice_sales_delivery_orders WHERE status='READY'),
      'partiallyShippedDeliveries',(SELECT count(*)
        FROM public.backoffice_sales_delivery_orders WHERE status='PARTIALLY_SHIPPED'),
      'inTransitDeliveries',(SELECT count(*)
        FROM public.backoffice_sales_delivery_orders WHERE status='IN_TRANSIT'),
      'outboundTransitWarehouses',(SELECT count(*) FROM public.warehouses
        WHERE is_active AND transit_operation='SALES_DELIVERY_OUTBOUND'),
      'rule','Dispatch requires physical Stock/FIFO; Reservation shortage remains unshipped') details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;


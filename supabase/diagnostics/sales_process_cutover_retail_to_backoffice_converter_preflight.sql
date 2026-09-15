-- Step 4B/6 SELECT-only preflight. Isolated Development only.
WITH required_versions(version) AS (VALUES
 ('20260909162000'::text),('20260909163000'),('20260910110000'),
 ('20260910120000'),('20260910130000'),('20260910140000'),
 ('20260910150000'),('20260910151000'),('20260910152000'),('20260910153000')),
checks AS (
 SELECT 'step_4b_dependency_ledger' check_name,
   CASE WHEN count(ledger.version)=10 THEN 'PASS' ELSE 'BLOCKER' END status,
   (10-count(ledger.version))::bigint violation_rows,
   jsonb_build_object('expected',10,'present',count(ledger.version)) details
 FROM required_versions required LEFT JOIN private.kgs_schema_migrations ledger USING(version)
 UNION ALL SELECT 'step_4b_converter_collision',
   CASE WHEN to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') IS NULL THEN 'PASS' ELSE 'BLOCKER' END,
   CASE WHEN to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') IS NULL THEN 0 ELSE 1 END,
   jsonb_build_object('existing',to_regprocedure('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)') IS NOT NULL)
 UNION ALL SELECT 'step_4b_open_plan_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*)::bigint,jsonb_build_object('openPlans',count(*)) FROM public.sales_process_cutover_plans
   WHERE status IN('DRAFT','PREVIEWED','APPLYING')
 UNION ALL SELECT 'step_4b_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*)::bigint,jsonb_build_object('activeRuns',count(*)) FROM public.finance_posting_queue_runs
   WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'step_4b_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*)::bigint,jsonb_build_object('submissions',count(*)) FROM public.pos_offline_sale_submissions
   WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
 UNION ALL SELECT 'step_4b_convertible_retail_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'INFO' END,
   count(*)::bigint,jsonb_build_object('invalidDocuments',count(*)) FROM public.sales_headers sale
   WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
     AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED')
     AND (NOT EXISTS(SELECT 1 FROM public.sales_details detail WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id)
       OR EXISTS(SELECT 1 FROM public.sales_details detail WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id
         GROUP BY detail.product_uom_id HAVING detail.product_uom_id IS NULL OR count(*)<>1))
 UNION ALL SELECT 'step_4b_retail_active_master_boundary',
   CASE WHEN count(*)=0 THEN 'PASS' ELSE 'INFO' END,count(*)::bigint,
   jsonb_build_object('invalidDocuments',count(*),
     'rule','Converter fails closed when Store, Customer, sale-source Warehouse, Product-UOM, Product, or UOM is inactive')
 FROM public.sales_headers sale
 WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
   AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED')
   AND (NOT EXISTS(SELECT 1 FROM public.stores store
       WHERE store.company_id=sale.company_id AND store.id=sale.store_id
         AND store.status='ACTIVE')
     OR NOT EXISTS(SELECT 1 FROM public.customers customer
       WHERE customer.company_id=sale.company_id AND customer.id=sale.customer_id
         AND customer.is_active)
     OR NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
       WHERE warehouse.company_id=sale.company_id
         AND warehouse.id=sale.sales_warehouse_id
         AND warehouse.is_active AND warehouse.is_sale_source)
     OR EXISTS(SELECT 1 FROM public.sales_details detail
       LEFT JOIN public.product_uoms product_uom
         ON product_uom.company_id=detail.company_id
        AND product_uom.id=detail.product_uom_id
        AND product_uom.product_id=detail.product_id
       LEFT JOIN public.products product ON product.company_id=product_uom.company_id
         AND product.id=product_uom.product_id
       LEFT JOIN public.uoms uom ON uom.company_id=product_uom.company_id
         AND uom.id=product_uom.uom_id
       WHERE detail.company_id=sale.company_id AND detail.sales_id=sale.id
         AND (product_uom.id IS NULL OR NOT product_uom.is_active
           OR NOT product_uom.sales_allowed OR NOT product.is_active
           OR NOT uom.is_active)))
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;

-- Company automatic Surat Jalan policy preflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_dependency' check_name,
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260827152000') THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('requiredVersion','20260827152000') details
  UNION ALL
  SELECT 'unexpected_pickup_delivery_history',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('documentCount',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id
  WHERE sale.fulfillment_mode<>'DELIVERY'
  UNION ALL
  SELECT 'canonical_sales_document_runtime',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',4,'routineRows',count(*))
  FROM (VALUES
    ('private.ensure_sales_documents(uuid,uuid,text)'),
    ('private.acp5e_update_sales_delivery_status_core(uuid,bigint,text,text)'),
    ('public.get_inventory_delivery_documents(date,date)'),
    ('public.save_company_document_visibility(bigint,boolean,boolean,boolean,text,text)')
  ) required(signature)
  WHERE to_regprocedure(required.signature) IS NOT NULL
  UNION ALL
  SELECT 'active_company_policy_scope','INFO',jsonb_build_object(
    'activeCompanies',count(*),'companiesWithBranding',count(branding.company_id))
  FROM public.companies company
  LEFT JOIN public.company_branding_profiles branding ON branding.company_id=company.id
  WHERE company.status='ACTIVE'
  UNION ALL
  SELECT 'sales_document_runtime_inventory','INFO',jsonb_build_object(
    'postedSales',count(*) FILTER(WHERE sale.document_status='POSTED'),
    'pickupPostedSales',count(*) FILTER(WHERE sale.document_status='POSTED'
      AND sale.fulfillment_mode='PICKUP'),
    'deliveryPostedSales',count(*) FILTER(WHERE sale.document_status='POSTED'
      AND sale.fulfillment_mode='DELIVERY'),
    'deliveryDocuments',(SELECT count(*) FROM public.sales_delivery_documents))
  FROM public.sales_headers sale
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

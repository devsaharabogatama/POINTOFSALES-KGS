-- SELECT-only, single-result preflight for a mass zero-price Customer
-- Pricelist assigned only to KGFF Customer KGS003 / SALES KGS.
-- This statement performs no mutation.

WITH required(version) AS (
  VALUES ('20260722070000'::text),('20260722100000'::text),
    ('20260729070000'::text),('20260729100000'::text),
    ('20261008130000'::text)
), installed AS (
  SELECT migration.version FROM private.kgs_schema_migrations migration
  JOIN required ON required.version=migration.version
), company_target AS (
  SELECT company.id,company.company_code,company.company_name,company.status
  FROM public.companies company WHERE company.company_code='KGFF'
), customer_target AS (
  SELECT customer.id,customer.company_id,customer.code,customer.name,
    customer.is_active,customer.is_system_customer,
    customer.default_pricelist_id,customer.master_version
  FROM public.customers customer
  JOIN company_target company ON company.id=customer.company_id
  WHERE customer.code='KGS003' AND customer.name='SALES KGS'
), catalog_target AS (
  SELECT product.id product_id,product.sku,product.name product_name,
    product_uom.id product_uom_id,product_uom.uom_id,
    product_uom.sale_price,unit.code uom_code,unit.name uom_name
  FROM company_target company
  JOIN public.products product ON product.company_id=company.id
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=product.company_id
   AND product_uom.product_id=product.id
  JOIN public.uoms unit ON unit.company_id=product_uom.company_id
   AND unit.id=product_uom.uom_id
  WHERE company.status='ACTIVE' AND product.is_active AND NOT product.is_bundle
    AND product_uom.is_active AND product_uom.sales_allowed AND unit.is_active
), duplicate_uom AS (
  SELECT product_uom_id FROM catalog_target
  GROUP BY product_uom_id HAVING count(*)<>1
), installation_target AS (
  SELECT pricelist.id,pricelist.code,pricelist.name,pricelist.scope,
    pricelist.is_active,pricelist.master_version,
    (SELECT count(*) FROM public.pricelist_rules rule
      WHERE rule.company_id=pricelist.company_id
        AND rule.pricelist_id=pricelist.id AND rule.is_active) active_rules
  FROM public.pricelists pricelist
  JOIN company_target company ON company.id=pricelist.company_id
  WHERE pricelist.code='SAMPLE-SALES-KGS'
    OR lower(regexp_replace(btrim(pricelist.name),'\s+',' ','g'))
      =lower('Sample SALES KGS')
), activity AS (
  SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs queue
      WHERE queue.company_id=(SELECT id FROM company_target)
        AND queue.status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions submission
      WHERE submission.company_id=(SELECT id FROM company_target)
        AND submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) nonterminal_offline
), checks AS (
  SELECT 1 ordinal,
    'kgff_sales_kgs_sample_pricelist_dependency_ledger'::text check_name,
    CASE WHEN (SELECT count(*) FROM installed)=(SELECT count(*) FROM required)
      THEN 'PASS' ELSE 'BLOCKER' END status,
    ((SELECT count(*) FROM required)-(SELECT count(*) FROM installed))::bigint violation_rows,
    jsonb_build_object(
      'required',(SELECT jsonb_agg(version ORDER BY version) FROM required),
      'installed',(SELECT jsonb_agg(version ORDER BY version) FROM installed)) details
  UNION ALL
  SELECT 2,'kgff_sales_kgs_sample_pricelist_company_identity',
    CASE WHEN count(*)=1 AND bool_and(status='ACTIVE') THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(status='ACTIVE') THEN 0 ELSE count(*) END,
    jsonb_build_object('rows',count(*),
      'companies',COALESCE(jsonb_agg(company_target),'[]'::jsonb))
  FROM company_target
  UNION ALL
  SELECT 3,'kgff_sales_kgs_sample_pricelist_customer_identity',
    CASE WHEN count(*)=1 AND bool_and(is_active) AND NOT bool_or(is_system_customer)
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(is_active) AND NOT bool_or(is_system_customer)
      THEN 0 ELSE count(*) END,
    jsonb_build_object('rows',count(*),
      'customers',COALESCE(jsonb_agg(customer_target),'[]'::jsonb))
  FROM customer_target
  UNION ALL
  SELECT 4,'kgff_sales_kgs_sample_pricelist_catalog_contract',
    CASE WHEN (SELECT count(*) FROM catalog_target)>0
      AND NOT EXISTS(SELECT 1 FROM duplicate_uom) THEN 'PASS' ELSE 'BLOCKER' END,
    (SELECT count(*) FROM duplicate_uom),
    jsonb_build_object(
      'activeSaleUoms',(SELECT count(*) FROM catalog_target),
      'zeroBasePrices',(SELECT count(*) FROM catalog_target WHERE sale_price=0),
      'rulesRequired',(SELECT count(*) FROM catalog_target))
  UNION ALL
  SELECT 5,'kgff_sales_kgs_sample_pricelist_installation_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    CASE WHEN count(*)=0 THEN 0 ELSE count(*) END,
    jsonb_build_object('classification',CASE WHEN count(*)=0
      THEN 'NOT_INSTALLED' ELSE 'PARTIAL_OR_INSTALLED' END,
      'rows',COALESCE(jsonb_agg(installation_target),'[]'::jsonb))
  FROM installation_target
  UNION ALL
  SELECT 6,'kgff_sales_kgs_sample_pricelist_runtime_objects',
    CASE WHEN
      to_regprocedure('public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)') IS NOT NULL
      AND to_regprocedure('public.save_customer_with_pricelist(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean,uuid,uuid)') IS NOT NULL
      AND to_regprocedure('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)') IS NOT NULL
    THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN
      to_regprocedure('public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)') IS NOT NULL
      AND to_regprocedure('public.save_customer_with_pricelist(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean,uuid,uuid)') IS NOT NULL
      AND to_regprocedure('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)') IS NOT NULL
    THEN 0 ELSE 1 END,
    jsonb_build_object(
      'pricelistWriter',to_regprocedure('public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)') IS NOT NULL,
      'customerWriter',to_regprocedure('public.save_customer_with_pricelist(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean,uuid,uuid)') IS NOT NULL,
      'resolver',to_regprocedure('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)') IS NOT NULL)
  UNION ALL
  SELECT 7,'kgff_sales_kgs_sample_pricelist_runtime_boundary',
    CASE WHEN active_finance_queue=0 AND nonterminal_offline=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    active_finance_queue+nonterminal_offline,to_jsonb(activity) FROM activity
  UNION ALL
  SELECT 8,'kgff_sales_kgs_sample_pricelist_business_boundary','INFO',0,
    jsonb_build_object(
      'planned',ARRAY['one KGFF Customer Pricelist',
        'all active sale Product-UOM fixed to zero',
        'assignment only to KGS003 / SALES KGS'],
      'preserved',ARRAY['Product base prices',
        'Global and other Customer Pricelists','other Customers and Companies',
        'existing Draft and Posted Sales','Stock/FIFO/Payment/Finance configuration'],
      'remainingSeparateGate','zero-total Sample checkout and Expense journal behavior',
      'mutation','NONE')
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY ordinal;

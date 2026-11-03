-- SELECT-only preflight for Retail POS nominal Product discount semantics.
-- One statement/result set is intentional: Supabase SQL Editor must display
-- every mandatory gate row together. No DDL, DML, or side-effecting call.

WITH required(version) AS (
  VALUES
    ('20260721180000'),('20260729070000'),('20260730010000'),
    ('20260825120000'),('20260909140000'),('20260909162000'),
    ('20261031110000'),('20261102150000')
), installed AS (
  SELECT ledger.version FROM private.kgs_schema_migrations ledger
  WHERE ledger.version IN(SELECT version FROM required)
), missing AS (
  SELECT version FROM required EXCEPT SELECT version FROM installed
), installation_state AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version='20261102160000') AS ledger,
    EXISTS(SELECT 1 FROM information_schema.columns column_state
      WHERE column_state.table_schema='public'
        AND column_state.table_name='products'
        AND column_state.column_name='pos_line_discount_amount_basis') AS product_column,
    EXISTS(SELECT 1 FROM information_schema.columns column_state
      WHERE column_state.table_schema='public'
        AND column_state.table_name='sales_details'
        AND column_state.column_name='line_discount_amount_basis') AS detail_column,
    to_regprocedure('private.reprice_pos_sale_draft_before_per_unit_discount(uuid,uuid,uuid,jsonb,timestamptz)') IS NOT NULL AS runtime_wrapper,
    to_regprocedure('public.get_pos_offline_catalog_snapshot_before_discount_basis(uuid)') IS NOT NULL AS offline_wrapper
), runtime AS (
  SELECT
    pg_get_functiondef(to_regprocedure('private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamptz)')) AS pos_reprice,
    pg_get_functiondef(to_regprocedure('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)')) AS backoffice_save,
    pg_get_functiondef(to_regprocedure('public.get_pos_offline_catalog_snapshot(uuid)')) AS offline_catalog
), retail_company AS (
  SELECT company.id,company.company_code,company.company_name
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
), candidates AS (
  SELECT retail_company.company_code,product.id,product.sku,product.name,
    product.is_active,product.master_version
  FROM retail_company
  JOIN public.products product ON product.company_id=retail_company.id
  WHERE (product.sku='L' AND product.name='Lettuce')
     OR (product.sku='BB' AND product.name='Bawang Bombay')
), invalid_candidates AS (
  SELECT * FROM candidates WHERE NOT is_active
), collisions AS (
  SELECT company_code,sku,count(*) AS rows
  FROM candidates GROUP BY company_code,sku HAVING count(*)>1
), retail_draft AS (
  SELECT sale.id,sale.company_id,sale.draft_no,sale.created_at,sale.payload_snapshot
  FROM public.sales_headers sale
  WHERE sale.document_status='DRAFT' AND sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
), amount_line AS (
  SELECT draft.company_id,draft.draft_no,draft.created_at,line.value AS payload_line
  FROM retail_draft draft
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(draft.payload_snapshot->'lines','[]'::jsonb)) line
  WHERE line.value->>'lineDiscountType'='AMOUNT'
    AND COALESCE((line.value->>'lineDiscountInput')::numeric,0)>0
), resolved_legacy AS (
  SELECT company.company_code,line.draft_no,line.created_at,
    product.sku,product.name,uom.name AS uom_name,
    (line.payload_line->>'quantity')::numeric AS quantity,
    (line.payload_line->>'lineDiscountInput')::numeric AS discount_input,
    line.payload_line ? 'lineDiscountAmountBasis' AS basis_present
  FROM amount_line line
  JOIN public.companies company ON company.id=line.company_id
  JOIN public.product_uoms product_uom
    ON product_uom.company_id=line.company_id
   AND product_uom.id=(line.payload_line->>'productUomId')::uuid
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id
  JOIN public.uoms uom ON uom.company_id=product_uom.company_id
    AND uom.id=product_uom.uom_id
), nonterminal AS (
  SELECT submission.id,submission.payload_snapshot
  FROM public.pos_offline_sale_submissions submission
  WHERE submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
), offline_amount_lines AS (
  SELECT submission.id
  FROM nonterminal submission
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(submission.payload_snapshot->'lines','[]'::jsonb)) line
  WHERE line.value->>'lineDiscountType'='AMOUNT'
    AND COALESCE((line.value->>'lineDiscountInput')::numeric,0)>0
)
SELECT 'pos_retail_per_unit_discount_dependency_ledger' AS check_name,
  CASE WHEN NOT EXISTS(SELECT 1 FROM missing) THEN 'PASS' ELSE 'BLOCKER' END AS status,
  (SELECT count(*) FROM missing) AS violation_rows,
  jsonb_build_object('required',(SELECT jsonb_agg(version ORDER BY version) FROM required),
    'missing',COALESCE((SELECT jsonb_agg(version ORDER BY version) FROM missing),'[]'::jsonb)) AS details
UNION ALL
SELECT 'pos_retail_per_unit_discount_installation_state',
  CASE WHEN NOT ledger AND NOT product_column AND NOT detail_column
      AND NOT runtime_wrapper AND NOT offline_wrapper THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN NOT ledger AND NOT product_column AND NOT detail_column
      AND NOT runtime_wrapper AND NOT offline_wrapper THEN 0 ELSE 1 END,
  jsonb_build_object('classification',CASE
      WHEN NOT ledger AND NOT product_column AND NOT detail_column
        AND NOT runtime_wrapper AND NOT offline_wrapper THEN 'NOT_INSTALLED'
      WHEN ledger AND product_column AND detail_column
        AND runtime_wrapper AND offline_wrapper THEN 'INSTALLED_CONSISTENT'
      ELSE 'PARTIAL_INCONSISTENT' END,
    'ledger',ledger,'productColumn',product_column,'detailColumn',detail_column,
    'runtimeWrapper',runtime_wrapper,'offlineWrapper',offline_wrapper)
FROM installation_state
UNION ALL
SELECT 'pos_retail_per_unit_discount_runtime_anchors',
  CASE WHEN pos_reprice LIKE '%reprice_pos_sale_draft_before_terminal_override%'
      AND backoffice_save IS NOT NULL AND offline_catalog LIKE '%productUoms%'
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN pos_reprice LIKE '%reprice_pos_sale_draft_before_terminal_override%'
      AND backoffice_save IS NOT NULL AND offline_catalog LIKE '%productUoms%'
    THEN 0 ELSE 1 END,
  jsonb_build_object('posRepriceMd5',md5(pos_reprice),
    'backofficeSaveMd5',md5(backoffice_save),'offlineCatalogMd5',md5(offline_catalog),
    'terminalOverrideWrapper',COALESCE(pos_reprice LIKE '%reprice_pos_sale_draft_before_terminal_override%',false))
FROM runtime
UNION ALL
SELECT 'pos_retail_per_unit_discount_exception_products',
  CASE WHEN NOT EXISTS(SELECT 1 FROM invalid_candidates)
      AND NOT EXISTS(SELECT 1 FROM collisions) THEN 'PASS' ELSE 'BLOCKER' END,
  (SELECT count(*) FROM invalid_candidates)+(SELECT count(*) FROM collisions),
  jsonb_build_object('retailCompanies',(SELECT jsonb_agg(jsonb_build_object(
      'code',company_code,'name',company_name) ORDER BY company_code) FROM retail_company),
    'exactProducts',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'company',company_code,'sku',sku,'name',name,'active',is_active,
      'masterVersion',master_version) ORDER BY company_code,sku) FROM candidates),'[]'::jsonb),
    'rule','Only exact L/Lettuce and BB/Bawang Bombay rows are LINE_TOTAL; missing Products are not created')
UNION ALL
SELECT 'pos_retail_per_unit_discount_legacy_draft_partition','PASS',0,
  jsonb_build_object('openRetailDrafts',(SELECT count(*) FROM retail_draft),
    'amountLines',(SELECT count(*) FROM resolved_legacy),
    'withoutBasis',(SELECT count(*) FROM resolved_legacy WHERE NOT basis_present),
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'company',company_code,'draftNo',draft_no,'createdAt',created_at,
      'sku',sku,'product',name,'uom',uom_name,'quantity',quantity,
      'discountInput',discount_input,'basisPresent',basis_present)
      ORDER BY created_at,draft_no) FROM resolved_legacy),'[]'::jsonb),
    'compatibility','Every legacy AMOUNT line must be snapshotted as LINE_TOTAL before new semantics activate')
UNION ALL
SELECT 'pos_retail_per_unit_discount_offline_boundary',
  CASE WHEN NOT EXISTS(SELECT 1 FROM nonterminal) THEN 'PASS' ELSE 'BLOCKER' END,
  (SELECT count(*) FROM nonterminal),
  jsonb_build_object('nonterminalSubmissions',(SELECT count(*) FROM nonterminal),
    'amountDiscountLines',(SELECT count(*) FROM offline_amount_lines))
UNION ALL
SELECT 'pos_retail_per_unit_discount_business_boundary','INFO',0,
  jsonb_build_object('changed',jsonb_build_array(
      'direct Retail POS nominal Product discount basis',
      'Retail POS online/offline preview and payload','live Product editor subtotal'),
    'preserved',jsonb_build_array('Backoffice Sales Order whole-line nominal discount',
      'historical Posted Sale amounts','Percentage discount','Pricelist discount semantics',
      'Stock/Reservation/FIFO/HPP','Payment verification and Finance posting ownership'),
    'mutation','NONE')
ORDER BY check_name;

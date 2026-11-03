-- SELECT-only postflight for Retail POS per-unit Product nominal discount.
WITH migration AS (
  SELECT count(*) rows FROM private.kgs_schema_migrations ledger
  WHERE ledger.version='20261102160000'
), runtime AS (
  SELECT pg_get_functiondef(procedure.oid) definition,
    procedure.prosecdef security_definer
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.oid=to_regprocedure(
      'private.reprice_pos_sale_draft(uuid,uuid,uuid,jsonb,timestamptz)')
), backoffice_runtime AS (
  SELECT pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.oid=to_regprocedure(
      'private.apply_backoffice_sales_commercials(uuid,uuid,uuid,jsonb,timestamptz)')
), product_contract AS (
  SELECT count(*) total,
    count(*) FILTER(WHERE product.pos_line_discount_amount_basis='LINE_TOTAL')
      exception_rows,
    count(*) FILTER(WHERE product.pos_line_discount_amount_basis<>'PER_UNIT'
      AND NOT ((product.sku='L' AND product.name='Lettuce')
        OR (product.sku='BB' AND product.name='Bawang Bombay'))) invalid_rows,
    count(*) FILTER(WHERE ((product.sku='L' AND product.name='Lettuce')
        OR (product.sku='BB' AND product.name='Bawang Bombay'))
      AND product.pos_line_discount_amount_basis<>'LINE_TOTAL') invalid_exceptions
  FROM public.products product
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=product.company_id
   AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
  WHERE product.is_active
), draft_contract AS (
  SELECT count(*) FILTER(WHERE line.value->>'lineDiscountType'='AMOUNT'
      AND COALESCE((line.value->>'lineDiscountInput')::numeric,0)>0) amount_lines,
    count(*) FILTER(WHERE line.value->>'lineDiscountType'='AMOUNT'
      AND COALESCE((line.value->>'lineDiscountInput')::numeric,0)>0
      AND line.value->>'lineDiscountAmountBasis' IS NULL) missing_basis
  FROM public.sales_headers sale
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(sale.payload_snapshot->'lines','[]'::jsonb)) line(value)
  WHERE sale.document_status='DRAFT' AND sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
), effect_inventory AS (
  SELECT
    (SELECT count(*) FROM public.financial_events event
      WHERE event.source_table='pos_retail_per_unit_product_discount') event_rows,
    (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.reference_table='pos_retail_per_unit_product_discount') movement_rows
)
SELECT 'pos_retail_per_unit_discount_postflight_migration_ledger' check_name,
  CASE WHEN rows=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(1-rows) violation_rows,jsonb_build_object('ledgerRows',rows) details
FROM migration
UNION ALL
SELECT 'pos_retail_per_unit_discount_postflight_schema_contract',
  CASE WHEN EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='products'
          AND column_name='pos_line_discount_amount_basis' AND is_nullable='NO')
      AND EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='sales_details'
          AND column_name='line_discount_amount_basis' AND is_nullable='NO')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='products'
          AND column_name='pos_line_discount_amount_basis' AND is_nullable='NO')
      AND EXISTS(SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='sales_details'
          AND column_name='line_discount_amount_basis' AND is_nullable='NO')
    THEN 0 ELSE 1 END,
  jsonb_build_object('productColumn',EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='products'
        AND column_name='pos_line_discount_amount_basis'),
    'detailColumn',EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_details'
        AND column_name='line_discount_amount_basis'))
UNION ALL
SELECT 'pos_retail_per_unit_discount_postflight_product_contract',
  CASE WHEN invalid_rows=0 AND invalid_exceptions=0 AND exception_rows=4
    THEN 'PASS' ELSE 'FAIL' END,invalid_rows+invalid_exceptions+abs(4-exception_rows),
  jsonb_build_object('activeRetailProducts',total,'exceptionRows',exception_rows,
    'expectedExceptions',4,'invalidOrdinaryRows',invalid_rows,
    'invalidExceptionRows',invalid_exceptions)
FROM product_contract
UNION ALL
SELECT 'pos_retail_per_unit_discount_postflight_open_draft_contract',
  CASE WHEN missing_basis=0 THEN 'PASS' ELSE 'FAIL' END,missing_basis,
  jsonb_build_object('nominalDiscountLines',amount_lines,
    'missingBasis',missing_basis,
    'meaning','Every existing open Retail POS nominal-discount Draft has an explicit immutable basis')
FROM draft_contract
UNION ALL
SELECT 'pos_retail_per_unit_discount_postflight_runtime_contract',
  CASE WHEN count(*)=1 AND bool_and(security_definer)
      AND bool_and(definition LIKE '%LINE_DISCOUNT_AMOUNT_BASIS_MISMATCH%')
      AND bool_and(definition LIKE '%round(v_input*v_quantity,6)%')
      AND bool_and(definition LIKE '%v_sale.sales_origin<>''POS''%')
      AND bool_and(definition LIKE
        '%v_sale.sales_process_mode<>''RETAIL_CONFIRM_INVOICE''%')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=1 AND bool_and(security_definer)
      AND bool_and(definition LIKE '%LINE_DISCOUNT_AMOUNT_BASIS_MISMATCH%')
      AND bool_and(definition LIKE '%round(v_input*v_quantity,6)%')
      AND bool_and(definition LIKE '%v_sale.sales_origin<>''POS''%')
      AND bool_and(definition LIKE
        '%v_sale.sales_process_mode<>''RETAIL_CONFIRM_INVOICE''%')
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'definitionMd5',min(md5(definition)),
    'securityDefiner',COALESCE(bool_and(security_definer),false),
    'serverBasisValidation',COALESCE(bool_and(definition LIKE
      '%LINE_DISCOUNT_AMOUNT_BASIS_MISMATCH%'),false),
    'retailPosGuard',COALESCE(bool_and(definition LIKE
      '%v_sale.sales_origin<>''POS''%'),false))
FROM runtime
UNION ALL
SELECT 'pos_retail_per_unit_discount_postflight_backoffice_boundary',
  CASE WHEN count(*)>=1
      AND bool_and(definition NOT LIKE '%lineDiscountAmountBasis%')
      AND bool_or(definition LIKE '%WHEN ''AMOUNT'' THEN round(v_input,4)%')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)>=1
      AND bool_and(definition NOT LIKE '%lineDiscountAmountBasis%')
      AND bool_or(definition LIKE '%WHEN ''AMOUNT'' THEN round(v_input,4)%')
    THEN 0 ELSE 1 END,
  jsonb_build_object('runtimeRows',count(*),
    'wholeLineAmountPreserved',COALESCE(bool_or(definition LIKE
      '%WHEN ''AMOUNT'' THEN round(v_input,4)%'),false),
    'newBasisAbsent',COALESCE(bool_and(definition NOT LIKE
      '%lineDiscountAmountBasis%'),false))
FROM backoffice_runtime
UNION ALL
SELECT 'pos_retail_per_unit_discount_postflight_zero_business_effect',
  CASE WHEN event_rows=0 AND movement_rows=0 THEN 'PASS' ELSE 'FAIL' END,
  event_rows+movement_rows,jsonb_build_object('eventRows',event_rows,
    'movementRows',movement_rows,
    'meaning','Installation changes Product configuration and open Draft snapshots only; it creates no posted Stock or Finance effect')
FROM effect_inventory
UNION ALL
SELECT 'pos_retail_per_unit_discount_postflight_business_boundary','INFO',0,
  jsonb_build_object('changed',jsonb_build_array(
      'Retail POS ordinary Product nominal discount becomes per sold UOM',
      'Lettuce and Bawang Bombay retain whole-line nominal discount',
      'Retail POS Product editor live subtotal'),
    'preserved',jsonb_build_array('Backoffice Sales Order nominal discount',
      'percentage discount','historical Posted Sales','Stock/Reservation/FIFO/HPP',
      'payment verification','Finance posting','other Product pricing rules'),
    'next','Run rollback-only behavior, deploy database before client, then authenticated POS smoke and UAT');

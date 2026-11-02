-- SELECT-only closing verification for migration 20261030130000.
WITH
scope AS (
  SELECT company.id AS company_id,company.company_code,company.company_name,
         setting.active_mode,
         COALESCE(branding.delivery_document_creation_policy,'DELIVERY_ONLY')
           AS creation_policy
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  LEFT JOIN public.company_branding_profiles branding
    ON branding.company_id=company.id
  WHERE company.company_code='KGS' AND company.status='ACTIVE'
),
sale_scope AS (
  SELECT sale.* FROM public.sales_headers sale
  JOIN scope ON scope.company_id=sale.company_id
  WHERE sale.draft_no='DRF-20261030-000455'
),
runtime AS (
  SELECT pg_get_functiondef(
    'private.ensure_sales_documents(uuid,uuid,text)'::regprocedure) definition
),
effects AS (
  SELECT
    (SELECT count(*) FROM public.stock_movements movement JOIN sale_scope sale
      ON sale.company_id=movement.company_id AND sale.id=movement.reference_id
      WHERE movement.reference_table='sales_headers') movement_rows,
    (SELECT count(*) FROM public.financial_events event JOIN sale_scope sale
      ON sale.company_id=event.company_id AND sale.id=event.source_id
      WHERE event.source_table='sales_headers') event_rows,
    (SELECT count(*) FROM public.sales_payments payment JOIN sale_scope sale
      ON sale.company_id=payment.company_id AND sale.id=payment.sales_id) payment_rows,
    (SELECT count(*) FROM public.sales_invoice_snapshots invoice JOIN sale_scope sale
      ON sale.company_id=invoice.company_id AND sale.id=invoice.sales_id) invoice_rows,
    (SELECT count(*) FROM public.sales_delivery_documents delivery JOIN sale_scope sale
      ON sale.company_id=delivery.company_id AND sale.id=delivery.sales_id) delivery_rows,
    (SELECT count(*) FROM public.sale_fifo_allocations fifo JOIN sale_scope sale
      ON sale.company_id=fifo.company_id AND sale.id=fifo.sales_id) fifo_rows,
    (SELECT count(*) FROM public.negative_stock_sale_allocations neg_alloc
      JOIN sale_scope sale ON sale.company_id=neg_alloc.company_id
       AND sale.id=neg_alloc.sales_id) negative_allocation_rows
),
checks AS (
  SELECT 10 seq,'pos_retail_pickup_document_postflight_migration_ledger'::text check_name,
    CASE WHEN (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261030130000')=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261030130000')=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',(SELECT count(*)
      FROM private.kgs_schema_migrations WHERE version='20261030130000')) details
  UNION ALL
  SELECT 20,'pos_retail_pickup_document_postflight_runtime_contract',
    CASE WHEN definition LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%'
      AND definition ~ 'v_sale[.]sales_origin[[:space:]]*=[[:space:]]*''POS'''
      AND definition ~ 'v_sale[.]sales_process_mode[[:space:]]*=[[:space:]]*''RETAIL_CONFIRM_INVOICE'''
      AND definition ~ 'v_sale[.]fulfillment_mode[[:space:]]*=[[:space:]]*''PICKUP'''
      AND definition LIKE '%NOT v_pos_retail_pickup%'
      AND definition LIKE '%v_delivery_id IS NOT NULL%'
      AND definition ~ 'v_sale[.]fulfillment_mode[[:space:]]*=[[:space:]]*''DELIVERY'''
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%'
      AND definition ~ 'v_sale[.]sales_origin[[:space:]]*=[[:space:]]*''POS'''
      AND definition ~ 'v_sale[.]sales_process_mode[[:space:]]*=[[:space:]]*''RETAIL_CONFIRM_INVOICE'''
      AND definition ~ 'v_sale[.]fulfillment_mode[[:space:]]*=[[:space:]]*''PICKUP'''
      AND definition LIKE '%NOT v_pos_retail_pickup%'
      AND definition LIKE '%v_delivery_id IS NOT NULL%'
      AND definition ~ 'v_sale[.]fulfillment_mode[[:space:]]*=[[:space:]]*''DELIVERY'''
      THEN 0 ELSE 1 END,
    jsonb_build_object('directPosRetailPickupExcluded',
      definition LIKE '%NOT v_pos_retail_pickup%',
      'existingDeliveryPreserved',definition LIKE '%v_delivery_id IS NOT NULL%',
      'deliveryModePreserved',
        definition ~ 'v_sale[.]fulfillment_mode[[:space:]]*=[[:space:]]*''DELIVERY''')
  FROM runtime
  UNION ALL
  SELECT 30,'pos_retail_pickup_document_postflight_company_policy_unchanged',
    CASE WHEN creation_policy='ALL_POSTED_SALES' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN creation_policy='ALL_POSTED_SALES' THEN 0 ELSE 1 END,
    jsonb_build_object('creationPolicy',creation_policy,
      'meaning','Global Company policy remains unchanged; exception is process-aware')
  FROM scope
  UNION ALL
  SELECT 40,'pos_retail_pickup_document_postflight_exact_draft_unchanged',
    CASE WHEN sale.document_status='DRAFT'
      AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
      AND sale.confirmed_at IS NULL AND sale.confirmed_by IS NULL
      AND sale.confirmation_idempotency_key IS NULL AND sale.reservation_version=0
      AND effects.movement_rows=0 AND effects.event_rows=0
      AND effects.payment_rows=0 AND effects.invoice_rows=0
      AND effects.delivery_rows=0 AND effects.fifo_rows=0
      AND effects.negative_allocation_rows=0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN sale.document_status='DRAFT'
      AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
      AND effects.movement_rows=0 AND effects.event_rows=0
      AND effects.payment_rows=0 AND effects.invoice_rows=0
      AND effects.delivery_rows=0 AND effects.fifo_rows=0
      AND effects.negative_allocation_rows=0 THEN 0 ELSE 1 END,
    to_jsonb(effects)||jsonb_build_object('draftNo',sale.draft_no,
      'documentStatus',sale.document_status,
      'orderRuntimeStatus',sale.order_runtime_status)
  FROM sale_scope sale CROSS JOIN effects
  UNION ALL
  SELECT 50,'pos_retail_pickup_document_postflight_business_boundary','INFO',0,
    jsonb_build_object('changed',jsonb_build_array(
      'new direct POS Retail Pickup automatic Delivery Document creation'),
      'preserved',jsonb_build_array('Invoice','Retail Delivery','Backoffice',
        'adopted cutover','existing Delivery Documents','Stock','FIFO',
        'negative-stock allocation','Payment','Finance','cashier session'),
      'next','Database gates closed; run authenticated POS Pickup smoke')
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;

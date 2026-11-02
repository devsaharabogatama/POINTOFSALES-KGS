-- SELECT-only diagnosis for the failed rollback-only behavior of the exact
-- KGS Retail Pickup Draft. This file performs no mutation and does not call
-- the posting RPC. It classifies the two observed mismatches:
--   delivery rows = 1, FIFO rows = 0.
WITH
scope AS (
  SELECT company.id AS company_id,
         company.company_code,
         company.company_name,
         setting.active_mode
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE company.company_code='KGS'
    AND company.status='ACTIVE'
    AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
),
sale_scope AS (
  SELECT sale.*
  FROM public.sales_headers sale
  JOIN scope ON scope.company_id=sale.company_id
  WHERE sale.draft_no='DRF-20261030-000455'
),
document_policy AS (
  SELECT scope.company_id,
         COALESCE(profile.delivery_document_creation_policy,
                  'DELIVERY_ONLY') AS creation_policy
  FROM scope
  LEFT JOIN public.company_branding_profiles profile
    ON profile.company_id=scope.company_id
),
requirement_by_product AS (
  SELECT requirement.company_id,
         requirement.sales_id,
         requirement.stock_product_id,
         min(product.sku) AS product_sku,
         min(product.name) AS product_name,
         min(product.cogs) AS product_cogs,
         sum(requirement.quantity_base) AS required_base_qty
  FROM public.sale_stock_requirements requirement
  JOIN sale_scope sale
    ON sale.company_id=requirement.company_id
   AND sale.id=requirement.sales_id
  JOIN public.products product
    ON product.company_id=requirement.company_id
   AND product.id=requirement.stock_product_id
  GROUP BY requirement.company_id,requirement.sales_id,
           requirement.stock_product_id
),
stock_route AS (
  SELECT requirement.*,
         sale.sales_warehouse_id AS warehouse_id,
         COALESCE(stock.stock_qty,0) AS stock_qty,
         COALESCE(batch.fifo_qty,0) AS positive_fifo_qty,
         GREATEST(LEAST(COALESCE(stock.stock_qty,0),
                        COALESCE(batch.fifo_qty,0)),0) AS fifo_available_qty,
         GREATEST(requirement.required_base_qty-
                    GREATEST(LEAST(COALESCE(stock.stock_qty,0),
                                   COALESCE(batch.fifo_qty,0)),0),0)
           AS expected_negative_qty,
         warehouse.is_active AS warehouse_active,
         warehouse.is_sale_source,
         warehouse.allow_negative_stock,
         warehouse.master_version AS negative_warehouse_version,
         COALESCE(batch.latest_fifo_cost,requirement.product_cogs) AS cost_basis
  FROM requirement_by_product requirement
  JOIN sale_scope sale
    ON sale.company_id=requirement.company_id
   AND sale.id=requirement.sales_id
  JOIN public.warehouses warehouse
    ON warehouse.company_id=sale.company_id
   AND warehouse.id=sale.sales_warehouse_id
  LEFT JOIN public.product_stocks stock
    ON stock.company_id=requirement.company_id
   AND stock.product_id=requirement.stock_product_id
   AND stock.warehouse_id=sale.sales_warehouse_id
  LEFT JOIN LATERAL (
    SELECT sum(product_batch.qty_remaining)
             FILTER (WHERE product_batch.qty_remaining>0) AS fifo_qty,
           (array_agg(product_batch.cogs_unit
                      ORDER BY product_batch.created_at DESC,
                               product_batch.id DESC))[1] AS latest_fifo_cost
    FROM public.product_batches product_batch
    WHERE product_batch.company_id=requirement.company_id
      AND product_batch.product_id=requirement.stock_product_id
      AND product_batch.warehouse_id=sale.sales_warehouse_id
  ) batch ON true
),
side_effects AS (
  SELECT
    (SELECT count(*) FROM public.stock_movements movement
      JOIN sale_scope sale ON sale.company_id=movement.company_id
       AND sale.id=movement.reference_id
      WHERE movement.reference_table='sales_headers') AS movement_rows,
    (SELECT count(*) FROM public.financial_events event
      JOIN sale_scope sale ON sale.company_id=event.company_id
       AND sale.id=event.source_id
      WHERE event.source_table='sales_headers') AS event_rows,
    (SELECT count(*) FROM public.sales_payments payment
      JOIN sale_scope sale ON sale.company_id=payment.company_id
       AND sale.id=payment.sales_id) AS payment_rows,
    (SELECT count(*) FROM public.sales_invoice_snapshots invoice
      JOIN sale_scope sale ON sale.company_id=invoice.company_id
       AND sale.id=invoice.sales_id) AS invoice_rows,
    (SELECT count(*) FROM public.sales_delivery_documents delivery
      JOIN sale_scope sale ON sale.company_id=delivery.company_id
       AND sale.id=delivery.sales_id) AS delivery_rows,
    (SELECT count(*) FROM public.sale_fifo_allocations allocation
      JOIN sale_scope sale ON sale.company_id=allocation.company_id
       AND sale.id=allocation.sales_id) AS fifo_rows,
    (SELECT count(*) FROM public.pos_negative_stock_authorizations authz
      JOIN sale_scope sale ON sale.company_id=authz.company_id
       AND sale.id=authz.sales_id) AS negative_authorization_rows,
    (SELECT count(*) FROM public.negative_stock_sale_allocations allocation
      JOIN sale_scope sale ON sale.company_id=allocation.company_id
       AND sale.id=allocation.sales_id) AS negative_allocation_rows
),
checks AS (
  SELECT 10 AS seq,
         'pos_retail_behavior_diagnosis_identity'::text AS check_name,
         CASE WHEN (SELECT count(*) FROM scope)=1
                   AND (SELECT count(*) FROM sale_scope)=1
                   AND (SELECT count(*) FROM private.kgs_schema_migrations
                        WHERE version='20261030120000')=1
              THEN 'PASS' ELSE 'BLOCKER' END AS status,
         CASE WHEN (SELECT count(*) FROM scope)=1
                   AND (SELECT count(*) FROM sale_scope)=1
                   AND (SELECT count(*) FROM private.kgs_schema_migrations
                        WHERE version='20261030120000')=1
              THEN 0 ELSE 1 END AS violation_rows,
         jsonb_build_object(
           'migrationRows',(SELECT count(*) FROM private.kgs_schema_migrations
                            WHERE version='20261030120000'),
           'company',(SELECT to_jsonb(scope) FROM scope),
           'sale',(SELECT jsonb_build_object(
             'id',sale.id,'draftNo',sale.draft_no,
             'documentStatus',sale.document_status,
             'orderRuntimeStatus',sale.order_runtime_status,
             'salesOrigin',sale.sales_origin,
             'salesProcessMode',sale.sales_process_mode,
             'fulfillmentMode',sale.fulfillment_mode,
             'sjRequired',sale.sj_required,
             'warehouseId',sale.sales_warehouse_id,
             'createdBy',sale.created_by,'masterVersion',sale.master_version)
             FROM sale_scope sale)) AS details
  UNION ALL
  SELECT 20,'pos_retail_behavior_diagnosis_failed_test_rollback',
         CASE WHEN sale.document_status='DRAFT'
                   AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
                   AND sale.confirmed_at IS NULL
                   AND sale.confirmed_by IS NULL
                   AND sale.confirmation_idempotency_key IS NULL
                   AND sale.reservation_version=0
                   AND effects.movement_rows=0 AND effects.event_rows=0
                   AND effects.payment_rows=0 AND effects.invoice_rows=0
                   AND effects.delivery_rows=0 AND effects.fifo_rows=0
                   AND effects.negative_authorization_rows=0
                   AND effects.negative_allocation_rows=0
              THEN 'PASS' ELSE 'BLOCKER' END,
         CASE WHEN sale.document_status='DRAFT'
                   AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
                   AND effects.movement_rows=0 AND effects.event_rows=0
                   AND effects.payment_rows=0 AND effects.invoice_rows=0
                   AND effects.delivery_rows=0 AND effects.fifo_rows=0
                   AND effects.negative_authorization_rows=0
                   AND effects.negative_allocation_rows=0
              THEN 0 ELSE 1 END,
         to_jsonb(effects)||jsonb_build_object(
           'documentStatus',sale.document_status,
           'orderRuntimeStatus',sale.order_runtime_status,
           'meaning','The failed behavior transaction left no persisted effect')
  FROM sale_scope sale CROSS JOIN side_effects effects
  UNION ALL
  SELECT 30,'pos_retail_behavior_diagnosis_pickup_document_policy',
         CASE WHEN policy.creation_policy='ALL_POSTED_SALES'
              THEN 'ROOT_CAUSE' ELSE 'PASS' END,
         CASE WHEN policy.creation_policy='ALL_POSTED_SALES' THEN 1 ELSE 0 END,
         jsonb_build_object(
           'fulfillmentMode',sale.fulfillment_mode,
           'sjRequired',sale.sj_required,
           'creationPolicy',policy.creation_policy,
           'runtimeExpectedDeliveryDocument',
             sale.fulfillment_mode='DELIVERY'
             OR policy.creation_policy='ALL_POSTED_SALES',
           'approvedBusinessOutcome',
             'Retail Pickup must produce receipt/Invoice without Surat Jalan',
           'classification',CASE
             WHEN policy.creation_policy='ALL_POSTED_SALES'
             THEN 'COMPANY_CONFIGURATION_CONFLICT'
             ELSE 'DELIVERY_ROW_REQUIRES_PRODUCT_ROOT_CAUSE_AUDIT' END)
  FROM sale_scope sale CROSS JOIN document_policy policy
  UNION ALL
  SELECT 40,'pos_retail_behavior_diagnosis_stock_route',
         CASE
           WHEN NOT EXISTS(SELECT 1 FROM stock_route) THEN 'BLOCKER'
           WHEN EXISTS(SELECT 1 FROM stock_route route
                       WHERE route.expected_negative_qty>0
                         AND NOT (route.warehouse_active
                           AND route.is_sale_source
                           AND route.allow_negative_stock
                           AND route.negative_warehouse_version>0
                           AND route.cost_basis IS NOT NULL
                           AND route.cost_basis>=0)) THEN 'BLOCKER'
           WHEN EXISTS(SELECT 1 FROM stock_route route
                       WHERE route.expected_negative_qty>0)
             THEN 'ROOT_CAUSE'
           ELSE 'PASS' END,
         CASE
           WHEN NOT EXISTS(SELECT 1 FROM stock_route) THEN 1
           ELSE (SELECT count(*) FROM stock_route route
                 WHERE route.expected_negative_qty>0
                   AND NOT (route.warehouse_active
                     AND route.is_sale_source
                     AND route.allow_negative_stock
                     AND route.negative_warehouse_version>0
                     AND route.cost_basis IS NOT NULL
                     AND route.cost_basis>=0)) END,
         jsonb_build_object(
           'requirements',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'productId',route.stock_product_id,
             'sku',route.product_sku,'name',route.product_name,
             'requiredBaseQty',route.required_base_qty,
             'stockQty',route.stock_qty,
             'positiveFifoQty',route.positive_fifo_qty,
             'fifoAvailableQty',route.fifo_available_qty,
             'expectedNegativeQty',route.expected_negative_qty,
             'warehouseActive',route.warehouse_active,
             'warehouseSaleSource',route.is_sale_source,
             'warehouseAllowsNegative',route.allow_negative_stock,
             'negativeAuthoritySource','WAREHOUSE',
             'negativeWarehouseVersion',route.negative_warehouse_version,
             'costBasis',route.cost_basis)
             ORDER BY route.product_sku),jsonb_build_array()) FROM stock_route route),
           'interpretation',
             'FIFO rows are required only for positive FIFO quantity; under the current unified authority an opted-in sale-source Warehouse routes the shortage to negative_stock_sale_allocations')
  UNION ALL
  SELECT 50,'pos_retail_behavior_diagnosis_runtime_contract',
         CASE WHEN pg_get_functiondef(
                    'private.ensure_sales_documents(uuid,uuid,text)'::regprocedure)
                    LIKE '%delivery_document_creation_policy%'
                   AND pg_get_functiondef(
                    'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure)
                    LIKE '%negative_stock_sale_allocations%'
              THEN 'PASS' ELSE 'BLOCKER' END,
         CASE WHEN pg_get_functiondef(
                    'private.ensure_sales_documents(uuid,uuid,text)'::regprocedure)
                    LIKE '%delivery_document_creation_policy%'
                   AND pg_get_functiondef(
                    'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure)
                    LIKE '%negative_stock_sale_allocations%'
              THEN 0 ELSE 1 END,
         jsonb_build_object(
           'deliveryPolicyConsumer',true,
           'negativeAllocationConsumer',true,
           'negativeAuthority','WAREHOUSE',
           'mutation','NONE',
           'next','Classify Company policy and exact stock route before correcting product configuration or behavior assertions')
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY seq;

-- SELECT-only verification for the persistent AUTO_PO smoke fixture.
WITH constants AS (
  SELECT 'd290f1ee-6c54-4b01-90e6-d701748f0851'::uuid company_id,
    '08fc496d-af34-4d7e-8aad-4afe3762f1e0'::uuid actor_id,
    '6ba40fc1-48bf-4302-bf8d-d71432a34ff2'::uuid receiving_warehouse_id
), company_day AS (
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date business_date
  FROM constants JOIN public.companies company ON company.id=constants.company_id
), fixture_batch AS (
  SELECT batch.* FROM constants CROSS JOIN company_day
  JOIN public.purchase_daily_batches batch ON batch.company_id=constants.company_id
    AND batch.business_date=company_day.business_date
    AND batch.mode_snapshot='AUTO_PO'
), checks AS (
  SELECT 'fixture_batch_shape' check_name,
    CASE WHEN count(*)=1 AND bool_and(status='READY' AND line_count=4)
      THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 AND bool_and(status='READY' AND line_count=4)
      THEN 0 ELSE greatest(count(*),1) END::bigint violation_rows,
    jsonb_build_object('batches',count(*),'batchNumbers',COALESCE(jsonb_agg(batch_no),'[]')) details
  FROM fixture_batch
  UNION ALL
  SELECT 'fixture_generated_po_shape',
    CASE WHEN count(*)=4 AND bool_and(document.status='CONFIRMED'
      AND document.order_source='DAILY_REPLENISHMENT'
      AND document.supplier_assignment_status='ASSIGNED'
      AND document.destination_warehouse_id IS NULL
      AND EXISTS(SELECT 1 FROM public.supplier_order_lines line
        WHERE line.company_id=document.company_id
          AND line.document_id=document.id
          AND line.source_warehouse_id IS NOT NULL))
      THEN 'PASS' ELSE 'FAIL' END,
    (abs(4-count(*))+count(*) FILTER(WHERE document.status<>'CONFIRMED'
      OR document.order_source<>'DAILY_REPLENISHMENT'
      OR document.supplier_assignment_status<>'ASSIGNED'
      OR document.destination_warehouse_id IS NOT NULL
      OR NOT EXISTS(SELECT 1 FROM public.supplier_order_lines line
        WHERE line.company_id=document.company_id
          AND line.document_id=document.id
          AND line.source_warehouse_id IS NOT NULL)))::bigint,
    jsonb_build_object('purchaseOrders',count(*),
      'orderNumbers',COALESCE(jsonb_agg(document.order_no ORDER BY document.order_no),'[]'))
  FROM constants CROSS JOIN fixture_batch
  JOIN public.supplier_order_documents document
    ON document.company_id=constants.company_id
   AND document.purchase_daily_batch_id=fixture_batch.id
  UNION ALL
  SELECT 'fixture_supplier_split',
    CASE WHEN count(DISTINCT document.supplier_id)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(DISTINCT document.supplier_id))::bigint,
    jsonb_build_object('distinctSuppliers',count(DISTINCT document.supplier_id))
  FROM constants CROSS JOIN fixture_batch
  JOIN public.supplier_order_documents document
    ON document.company_id=constants.company_id
   AND document.purchase_daily_batch_id=fixture_batch.id
  UNION ALL
  SELECT 'fixture_scheduler_trace',
    CASE WHEN count(*)=1 AND bool_and(run.status='GENERATED'
      AND run.execution_actor='SYSTEM_AUTOMATION'
      AND run.actor_display_name='Sistem Otomatis') THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,
    jsonb_build_object('schedulerRuns',count(*))
  FROM constants CROSS JOIN company_day
  JOIN public.purchase_daily_scheduler_runs run ON run.company_id=constants.company_id
    AND run.business_date=company_day.business_date
  UNION ALL
  SELECT 'fixture_company_setting_restored',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,
    jsonb_build_object('requiredMode','AUTO_RO','matchingRows',count(*))
  FROM constants JOIN public.company_purchase_replenishment_settings setting
    ON setting.company_id=constants.company_id
   AND setting.replenishment_mode='AUTO_RO'
   AND setting.default_purchase_receipt_warehouse_id=constants.receiving_warehouse_id
  UNION ALL
  SELECT 'fixture_downstream_initial_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('unexpectedReceipts',count(*))
  FROM constants CROSS JOIN fixture_batch
  JOIN public.goods_receipt_documents receipt ON receipt.company_id=constants.company_id
  WHERE receipt.supplier_order_id IN(SELECT document.id
    FROM public.supplier_order_documents document
    WHERE document.company_id=constants.company_id
      AND document.purchase_daily_batch_id=fixture_batch.id)
  UNION ALL
  SELECT 'fixture_po_inventory','INFO',0::bigint,
    jsonb_build_object('purchaseOrders',COALESCE(jsonb_agg(jsonb_build_object(
      'orderNo',document.order_no,'supplier',supplier.supplier_name,
      'orderDate',document.order_date,'expectedDate',document.expected_date,
      'status',document.status,'estimatedTotal',document.estimated_total,
      'receivingWarehouse',warehouse.name) ORDER BY document.order_no),'[]'::jsonb))
  FROM constants CROSS JOIN fixture_batch
  JOIN public.supplier_order_documents document ON document.company_id=constants.company_id
    AND document.purchase_daily_batch_id=fixture_batch.id
  JOIN public.suppliers supplier ON supplier.company_id=document.company_id
    AND supplier.id=document.supplier_id
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
    AND warehouse.id=document.destination_warehouse_id
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 ELSE 1 END,check_name;

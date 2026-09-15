-- SELECT-only verification for Step 4/6.5C3. Run the whole file.
WITH checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912130000'
  UNION ALL
  SELECT 'c3_required_routines',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*)),jsonb_build_object('expected',4,'present',count(*))
  FROM (VALUES
    ('private.record_backoffice_sales_discrepancy_transfer_effect(uuid,uuid,uuid,text,uuid)'),
    ('private.post_backoffice_sales_exact_return_transfer(uuid,bigint,uuid,uuid)'),
    ('private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'),
    ('public.resolve_backoffice_sales_overage_wrong_item(uuid,bigint,uuid,date,text)')) expected(signature)
  WHERE to_regprocedure(expected.signature) IS NOT NULL
  UNION ALL
  SELECT 'c3_public_rpc_boundary',CASE WHEN anon_rows=0 AND authenticated_rows=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(authenticated_rows-1)+anon_rows,
    jsonb_build_object('anonExecute',anon_rows,'authenticatedExecute',authenticated_rows)
  FROM (SELECT count(*) FILTER(WHERE grantee='anon' AND privilege_type='EXECUTE') anon_rows,
      count(*) FILTER(WHERE grantee='authenticated' AND privilege_type='EXECUTE') authenticated_rows
    FROM information_schema.routine_privileges
    WHERE specific_schema='public' AND routine_name='resolve_backoffice_sales_overage_wrong_item') privilege
  UNION ALL
  SELECT 'c3_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE specific_schema='private' AND grantee IN('anon','authenticated')
    AND routine_name IN('record_backoffice_sales_discrepancy_transfer_effect',
      'post_backoffice_sales_exact_return_transfer',
      'resolve_backoffice_sales_overage_wrong_item_core') AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'c3_backorder_kind_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_discrepancy_backorders
  WHERE resolution_kind NOT IN('SHORT_BACKORDER','WRONG_ITEM_CORRECTION')
  UNION ALL
  SELECT 'c3_resolved_accepted_overage_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.requested_resolution='ACCEPT_OVERAGE' AND line.warehouse_resolution_status='RESOLVED'
    AND (line.commercial_approval_status<>'APPROVED'
      OR line.accepted_overage_base_qty<>line.quantity_base
      OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
        JOIN public.financial_events event ON event.company_id=effect.company_id
          AND event.id=effect.financial_event_id
        JOIN public.transaction_categories category ON category.company_id=event.company_id
          AND category.id=event.transaction_category_id
        WHERE effect.company_id=line.company_id AND effect.discrepancy_line_id=line.id
          AND effect.effect_type='OVERAGE_ACCEPTED_SALE' AND effect.financial_event_id IS NOT NULL
          AND event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
          AND category.system_key=event.system_event_key
          AND event.transaction_rule_version IS NOT NULL))
  UNION ALL
  SELECT 'c3_resolved_return_overage_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.requested_resolution='RETURN_OVERAGE' AND line.warehouse_resolution_status='RESOLVED'
    AND (NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
          WHERE effect.company_id=line.company_id AND effect.discrepancy_line_id=line.id
            AND effect.effect_type='OVERAGE_TO_TRANSIT')
      OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
          WHERE effect.company_id=line.company_id AND effect.discrepancy_line_id=line.id
            AND effect.effect_type='OVERAGE_RETURN_TO_SOURCE'))
  UNION ALL
  SELECT 'c3_resolved_wrong_item_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.requested_resolution='REPLACE_WRONG_ITEM' AND line.warehouse_resolution_status='RESOLVED'
    AND (NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
          WHERE effect.company_id=line.company_id AND effect.discrepancy_line_id=line.id
            AND effect.effect_type='ACTUAL_TO_TRANSIT')
      OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
          WHERE effect.company_id=line.company_id AND effect.discrepancy_line_id=line.id
            AND effect.effect_type='ACTUAL_RETURN_TO_SOURCE')
      OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
          WHERE effect.company_id=line.company_id AND effect.discrepancy_line_id=line.id
            AND effect.effect_type='EXPECTED_RETURN_TO_SOURCE')
      OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_backorder_lines child
          JOIN public.backoffice_sales_discrepancy_backorders header
            ON header.company_id=child.company_id AND header.id=child.backorder_id
          WHERE child.company_id=line.company_id AND child.discrepancy_line_id=line.id
            AND header.resolution_kind='WRONG_ITEM_CORRECTION'))
  UNION ALL
  SELECT 'c3_exact_return_fifo_provenance',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidAllocations',count(*))
  FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
  JOIN public.backoffice_sales_discrepancy_stock_effects effect
    ON effect.company_id=allocation.company_id AND effect.id=allocation.stock_effect_id
  JOIN public.backoffice_sales_delivery_discrepancy_lines line
    ON line.company_id=effect.company_id AND line.id=effect.discrepancy_line_id
  WHERE effect.effect_type IN('OVERAGE_RETURN_TO_SOURCE','ACTUAL_RETURN_TO_SOURCE',
      'EXPECTED_RETURN_TO_SOURCE')
    AND NOT EXISTS(
      SELECT 1 FROM public.stock_transfer_fifo_allocations source_allocation
      JOIN public.stock_transfer_lines source_line
        ON source_line.company_id=source_allocation.company_id
       AND source_line.id=source_allocation.line_id
      WHERE source_allocation.company_id=allocation.company_id
        AND source_allocation.destination_batch_id=allocation.source_batch_id
        AND ((effect.effect_type='OVERAGE_RETURN_TO_SOURCE'
              AND source_line.document_id=(SELECT source_effect.stock_transfer_document_id
                FROM public.backoffice_sales_discrepancy_stock_effects source_effect
                WHERE source_effect.company_id=effect.company_id
                  AND source_effect.discrepancy_line_id=effect.discrepancy_line_id
                  AND source_effect.effect_type='OVERAGE_TO_TRANSIT'))
          OR (effect.effect_type='ACTUAL_RETURN_TO_SOURCE'
              AND source_line.document_id=(SELECT source_effect.stock_transfer_document_id
                FROM public.backoffice_sales_discrepancy_stock_effects source_effect
                WHERE source_effect.company_id=effect.company_id
                  AND source_effect.discrepancy_line_id=effect.discrepancy_line_id
                  AND source_effect.effect_type='ACTUAL_TO_TRANSIT'))
          OR (effect.effect_type='EXPECTED_RETURN_TO_SOURCE'
              AND source_line.document_id IN(SELECT dispatch.stock_transfer_document_id
                FROM public.backoffice_sales_delivery_dispatches dispatch
                WHERE dispatch.company_id=line.company_id
                  AND dispatch.delivery_order_id=line.delivery_order_id))))
  UNION ALL
  SELECT 'c3_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'c3_runtime_inventory','INFO',0,jsonb_build_object(
    'acceptedOverageEffects',count(*) FILTER(WHERE effect_type='OVERAGE_ACCEPTED_SALE'),
    'returnOverageEffects',count(*) FILTER(WHERE effect_type='OVERAGE_RETURN_TO_SOURCE'),
    'wrongItemActualEffects',count(*) FILTER(WHERE effect_type='ACTUAL_RETURN_TO_SOURCE'))
  FROM public.backoffice_sales_discrepancy_stock_effects
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;

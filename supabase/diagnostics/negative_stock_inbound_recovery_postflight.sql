-- SELECT-only verification for 20260917140000.
WITH checks AS (
  SELECT 'inbound_recovery_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917140000'
  UNION ALL
  SELECT 'inbound_recovery_constraint_contract',
    CASE WHEN definition~'qty_change >' AND definition~'sales_headers'
      AND definition~'stock_transfer_documents' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'qty_change >' AND definition~'sales_headers'
      AND definition~'stock_transfer_documents' THEN 0 ELSE 1 END,
    jsonb_build_object('positiveInboundAllowed',definition~'qty_change >',
      'salesBoundaryPreserved',definition~'sales_headers',
      'transferBoundaryPreserved',definition~'stock_transfer_documents')
  FROM (SELECT pg_get_constraintdef(oid) definition FROM pg_constraint
    WHERE conrelid='public.stock_movements'::regclass
      AND conname='stock_movements_balance_after_controlled') source
  UNION ALL
  SELECT 'inbound_recovery_guard_contract',
    CASE WHEN normalized_definition~'new[.]qty_change<0'
      AND definition~'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'
      AND definition~'pos_negative_stock_authorizations'
      AND definition~'backoffice_negative_stock_allocations'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN normalized_definition~'new[.]qty_change<0'
      AND definition~'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'
      AND definition~'pos_negative_stock_authorizations'
      AND definition~'backoffice_negative_stock_allocations'
      THEN 0 ELSE 1 END,
    jsonb_build_object('outboundOnly',normalized_definition~'new[.]qty_change<0',
      'retailAuthorizationPreserved',definition~'pos_negative_stock_authorizations',
      'backofficeAuthorizationPreserved',definition~'backoffice_negative_stock_allocations')
  FROM (SELECT definition,
      regexp_replace(lower(definition),'[[:space:]]','','g') normalized_definition
    FROM (SELECT pg_get_functiondef(
      'private.trg_g4_guard_negative_sale_movement()'::regprocedure) definition) raw) source
  UNION ALL
  SELECT 'inbound_recovery_trigger_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1)::bigint,
    jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger WHERE tgrelid='public.stock_movements'::regclass
    AND tgname='g4_guard_negative_sale_movement' AND NOT tgisinternal
  UNION ALL
  SELECT 'inbound_recovery_existing_row_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.stock_movements movement
  WHERE movement.balance_after_base_qty<0 AND movement.qty_change<=0
    AND NOT ((movement.movement_type='SALE'::public.stock_movement_type
        AND movement.reference_table='sales_headers')
      OR (movement.movement_type='TRANSFER_OUT'::public.stock_movement_type
        AND movement.reference_table='stock_transfer_documents'))
), inventory AS (
  SELECT 'inbound_recovery_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'negativeStocks',(SELECT count(*) FROM public.product_stocks WHERE stock_qty<0),
      'positiveMovementsEndingNegative',(SELECT count(*) FROM public.stock_movements
        WHERE qty_change>0 AND balance_after_base_qty<0)) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

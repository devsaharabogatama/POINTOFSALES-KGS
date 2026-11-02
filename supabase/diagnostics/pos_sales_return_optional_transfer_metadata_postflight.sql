-- SELECT-only postflight after migration 20261102110000.
WITH constraint_state AS (
  SELECT pg_get_constraintdef(constraint_row.oid,true) definition
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname='sales_return_refunds'
    AND constraint_row.conname='sales_return_refund_transfer_contract'
    AND constraint_row.contype='c'
), core_state AS (
  SELECT pg_get_functiondef(
    'private.save_sales_return_draft_sld_r4_core(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'::regprocedure
  ) definition
), invalid AS (
  SELECT refund.id
  FROM public.sales_return_refunds refund
  WHERE (refund.payment_method_type_snapshot='TRANSFER' AND (
      (refund.transfer_destination IS NOT NULL
        AND btrim(refund.transfer_destination)='')
      OR (refund.transfer_reference IS NOT NULL
        AND btrim(refund.transfer_reference)='')
    )) OR (refund.payment_method_type_snapshot<>'TRANSFER' AND (
      refund.transfer_destination IS NOT NULL
      OR refund.transfer_reference IS NOT NULL
    ))
)
SELECT 'pos_return_optional_transfer_postflight_migration_ledger' check_name,
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(count(*)-1) violation_rows,
  jsonb_build_object('ledgerRows',count(*)) details
FROM private.kgs_schema_migrations WHERE version='20261102110000'
UNION ALL
SELECT 'pos_return_optional_transfer_postflight_constraint_contract',
  CASE WHEN count(*)=1
      AND bool_and(definition LIKE
        '%transfer_destination IS NULL OR btrim(transfer_destination) <>%')
      AND bool_and(definition LIKE
        '%transfer_reference IS NULL OR btrim(transfer_reference) <>%')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN count(*)=1
      AND bool_and(definition LIKE
        '%transfer_destination IS NULL OR btrim(transfer_destination) <>%')
      AND bool_and(definition LIKE
        '%transfer_reference IS NULL OR btrim(transfer_reference) <>%')
    THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'definition',max(definition))
FROM constraint_state
UNION ALL
SELECT 'pos_return_optional_transfer_postflight_core_contract',
  CASE WHEN definition NOT LIKE '%TRANSFER_REFUND_REFERENCE_REQUIRED%'
      AND definition LIKE
        '%NULLIF(btrim(v_refund->>''transferDestination''),'''') END,%'
      AND definition LIKE
        '%NULLIF(btrim(v_refund->>''transferReference''),'''') END,%'
      AND definition LIKE '%odr6d_returnable_sales_detail_quantity%'
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN definition NOT LIKE '%TRANSFER_REFUND_REFERENCE_REQUIRED%'
      AND definition LIKE
        '%NULLIF(btrim(v_refund->>''transferDestination''),'''') END,%'
      AND definition LIKE
        '%NULLIF(btrim(v_refund->>''transferReference''),'''') END,%'
      AND definition LIKE '%odr6d_returnable_sales_detail_quantity%'
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'requiresMetadata',definition LIKE '%TRANSFER_REFUND_REFERENCE_REQUIRED%',
    'blankNormalization',definition LIKE
      '%NULLIF(btrim(v_refund->>''transferDestination''),'''') END,%'
      AND definition LIKE
      '%NULLIF(btrim(v_refund->>''transferReference''),'''') END,%',
    'odrCompatibility',definition LIKE
      '%odr6d_returnable_sales_detail_quantity%',
    'definitionMd5',md5(definition)
  )
FROM core_state
UNION ALL
SELECT 'pos_return_optional_transfer_postflight_data_contract',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('invalidRows',count(*)) FROM invalid
UNION ALL
SELECT 'pos_return_optional_transfer_postflight_direct_return_boundary',
  CASE WHEN to_regprocedure(
      'public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)'
    ) IS NOT NULL
    AND definition LIKE '%direct_pos_request_hash%'
    AND definition LIKE '%RETAIL_CONFIRM_INVOICE%'
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN to_regprocedure(
      'public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)'
    ) IS NOT NULL
    AND definition LIKE '%direct_pos_request_hash%'
    AND definition LIKE '%RETAIL_CONFIRM_INVOICE%'
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'submitRpc',to_regprocedure(
      'public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)'
    )::text,
    'approvalGuardPreserved',definition LIKE '%direct_pos_request_hash%'
  )
FROM (SELECT pg_get_functiondef(
  'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure
) definition) post_core
UNION ALL
SELECT 'pos_return_optional_transfer_postflight_business_boundary','INFO',0,
  jsonb_build_object(
    'changed',jsonb_build_array(
      'Transfer destination optional',
      'Transfer reference optional',
      'blank Transfer metadata normalized to NULL'
    ),
    'preserved',jsonb_build_array(
      'proof URL optional and HTTPS when present',
      'Cash metadata-free',
      'Retail direct Return finalization',
      'Backoffice Return approval',
      'Stock/FIFO/HPP',
      'Cashier Session',
      'Finance Event/Journal',
      'historical rows',
      'tenant and retry guards'
    ),
    'next','Run rollback-only behavior test before client deployment'
  );

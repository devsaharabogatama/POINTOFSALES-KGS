-- SELECT-only preflight for optional Sales Return Transfer metadata.
-- Expected current state: 20261102100000 installed, corrective migration absent,
-- canonical core and table constraint still require destination + reference.
WITH dependency(version) AS (VALUES
  ('20260803010000'::text),
  ('20260811150000'),
  ('20260829110000'),
  ('20261102100000')
), installed AS (
  SELECT migration.version
  FROM private.kgs_schema_migrations migration
  WHERE migration.version IN(SELECT version FROM dependency)
), objects AS (
  SELECT
    to_regclass('public.sales_return_refunds') refunds_table,
    to_regprocedure(
      'private.save_sales_return_draft_sld_r4_core(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'
    ) draft_core,
    to_regprocedure(
      'private.save_sales_return_draft_sld_r4(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)'
    ) fee_core,
    to_regprocedure(
      'public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)'
    ) draft_rpc,
    to_regprocedure(
      'public.submit_pos_sales_return_with_delivery_fee(uuid,uuid,text,text,jsonb,jsonb,boolean,uuid)'
    ) submit_rpc
), constraint_state AS (
  SELECT constraint_row.oid,
    pg_get_constraintdef(constraint_row.oid,true) definition
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname='sales_return_refunds'
    AND constraint_row.conname='sales_return_refund_transfer_contract'
    AND constraint_row.contype='c'
), core_state AS (
  SELECT pg_get_functiondef(objects.draft_core) definition
  FROM objects WHERE objects.draft_core IS NOT NULL
), historical AS (
  SELECT
    count(*) FILTER(WHERE refund.payment_method_type_snapshot='TRANSFER') transfer_rows,
    count(*) FILTER(WHERE refund.payment_method_type_snapshot='TRANSFER'
      AND refund.transfer_destination IS NULL) transfer_null_destination,
    count(*) FILTER(WHERE refund.payment_method_type_snapshot='TRANSFER'
      AND refund.transfer_reference IS NULL) transfer_null_reference,
    count(*) FILTER(WHERE refund.payment_method_type_snapshot='TRANSFER'
      AND (coalesce(btrim(refund.transfer_destination),'')=''
        OR coalesce(btrim(refund.transfer_reference),'')='')) transfer_missing_metadata,
    count(*) FILTER(WHERE refund.payment_method_type_snapshot<>'TRANSFER'
      AND (refund.transfer_destination IS NOT NULL
        OR refund.transfer_reference IS NOT NULL)) nontransfer_with_metadata
  FROM public.sales_return_refunds refund
), migration_state AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102100000') direct_return_live,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102110000') corrective_ledger
), queue_state AS (
  SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) nonterminal_offline
)
SELECT 'pos_return_optional_transfer_preflight_dependency_ledger' check_name,
  CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
  4-count(*) violation_rows,
  jsonb_build_object(
    'required',(SELECT jsonb_agg(version ORDER BY version) FROM dependency),
    'installed',coalesce(jsonb_agg(version ORDER BY version),'[]'::jsonb)
  ) details
FROM installed
UNION ALL
SELECT 'pos_return_optional_transfer_preflight_installation_state',
  CASE WHEN direct_return_live AND NOT corrective_ledger
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN direct_return_live AND NOT corrective_ledger THEN 0 ELSE 1 END,
  jsonb_build_object(
    'classification',CASE
      WHEN direct_return_live AND NOT corrective_ledger THEN 'NOT_INSTALLED'
      WHEN direct_return_live AND corrective_ledger THEN 'INSTALLED'
      ELSE 'PARTIAL/INCONSISTENT' END,
    'directReturnLive',direct_return_live,
    'correctiveLedger',corrective_ledger
  )
FROM migration_state
UNION ALL
SELECT 'pos_return_optional_transfer_preflight_runtime_objects',
  CASE WHEN refunds_table IS NOT NULL AND draft_core IS NOT NULL
      AND fee_core IS NOT NULL AND draft_rpc IS NOT NULL AND submit_rpc IS NOT NULL
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN refunds_table IS NOT NULL AND draft_core IS NOT NULL
      AND fee_core IS NOT NULL AND draft_rpc IS NOT NULL AND submit_rpc IS NOT NULL
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'refundsTable',refunds_table::text,
    'draftCore',draft_core::text,
    'feeCore',fee_core::text,
    'draftRpc',draft_rpc::text,
    'submitRpc',submit_rpc::text
  )
FROM objects
UNION ALL
SELECT 'pos_return_optional_transfer_preflight_constraint_contract',
  CASE WHEN count(*)=1
      AND bool_and(definition LIKE '%payment_method_type_snapshot = ''TRANSFER''%')
      AND bool_and(definition LIKE '%btrim(transfer_destination)%')
      AND bool_and(definition LIKE '%btrim(transfer_reference)%')
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=1
      AND bool_and(definition LIKE '%payment_method_type_snapshot = ''TRANSFER''%')
      AND bool_and(definition LIKE '%btrim(transfer_destination)%')
      AND bool_and(definition LIKE '%btrim(transfer_reference)%')
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'rows',count(*),
    'definition',max(definition)
  )
FROM constraint_state
UNION ALL
SELECT 'pos_return_optional_transfer_preflight_core_contract',
  CASE WHEN count(*)=1
      AND bool_and(definition LIKE '%TRANSFER_REFUND_REFERENCE_REQUIRED%')
      AND bool_and(definition LIKE '%transferDestination%')
      AND bool_and(definition LIKE '%transferReference%')
      AND bool_and(definition LIKE '%odr6d_returnable_sales_detail_quantity%')
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=1
      AND bool_and(definition LIKE '%TRANSFER_REFUND_REFERENCE_REQUIRED%')
      AND bool_and(definition LIKE '%transferDestination%')
      AND bool_and(definition LIKE '%transferReference%')
      AND bool_and(definition LIKE '%odr6d_returnable_sales_detail_quantity%')
    THEN 0 ELSE 1 END,
  jsonb_build_object(
    'rows',count(*),
    'definitionMd5',max(md5(definition)),
    'requiresMetadata',coalesce(bool_and(
      definition LIKE '%TRANSFER_REFUND_REFERENCE_REQUIRED%'),false),
    'odrCompatibility',coalesce(bool_and(
      definition LIKE '%odr6d_returnable_sales_detail_quantity%'),false)
  )
FROM core_state
UNION ALL
SELECT 'pos_return_optional_transfer_preflight_historical_shape',
  CASE WHEN nontransfer_with_metadata=0 AND transfer_missing_metadata=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  nontransfer_with_metadata+transfer_missing_metadata,
  jsonb_build_object(
    'transferRows',transfer_rows,
    'transferNullDestination',transfer_null_destination,
    'transferNullReference',transfer_null_reference,
    'transferMissingMetadata',transfer_missing_metadata,
    'nonTransferWithMetadata',nontransfer_with_metadata,
    'meaning','Existing rows remain valid; no historical rewrite is planned'
  )
FROM historical
UNION ALL
SELECT 'pos_return_optional_transfer_preflight_runtime_boundary',
  CASE WHEN active_finance_queue=0 AND nonterminal_offline=0
    THEN 'PASS' ELSE 'BLOCKER' END,
  active_finance_queue+nonterminal_offline,
  jsonb_build_object(
    'activeFinanceQueue',active_finance_queue,
    'nonterminalOffline',nonterminal_offline
  )
FROM queue_state
UNION ALL
SELECT 'pos_return_optional_transfer_preflight_business_boundary','INFO',0,
  jsonb_build_object(
    'approved',jsonb_build_array(
      'Transfer destination optional',
      'Transfer reference optional',
      'Transfer proof URL optional',
      'blank metadata normalizes to NULL'
    ),
    'preserved',jsonb_build_array(
      'Cash refund metadata-free',
      'Retail direct Return finalization',
      'Backoffice Return approval',
      'Stock/FIFO/HPP',
      'Cashier Session',
      'Finance Event/Journal',
      'historical rows',
      'tenant and retry guards'
    ),
    'mutation','NONE'
  );

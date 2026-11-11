-- SELECT-only diagnosis for the installed-state Task 3 audit-lineage failure.
-- No Product, audit, open-item, Finance, Stock, or migration row is mutated.
WITH registry_stats AS (
  SELECT audit.company_id,count(*) AS audit_rows,
    count(*) FILTER(WHERE item.id IS NULL) AS missing_entity,
    count(*) FILTER(WHERE item.id IS NOT NULL
      AND audit.actor_id IS DISTINCT FROM item.created_by) AS actor_mismatch,
    count(*) FILTER(WHERE item.id IS NOT NULL
      AND audit.state_snapshot IS DISTINCT FROM to_jsonb(item)) AS snapshot_mismatch
  FROM public.ar_open_item_audit audit
  LEFT JOIN public.ar_open_item_registry item
    ON item.company_id=audit.company_id AND item.id=audit.entity_id
  WHERE audit.entity_kind='REGISTRY'
  GROUP BY audit.company_id
), operation_stats AS (
  SELECT audit.company_id,count(*) AS audit_rows,
    count(*) FILTER(WHERE operation.id IS NULL) AS missing_entity,
    count(*) FILTER(WHERE operation.id IS NOT NULL
      AND audit.actor_id IS DISTINCT FROM operation.actor_id) AS actor_mismatch,
    count(*) FILTER(WHERE operation.id IS NOT NULL
      AND audit.state_snapshot IS DISTINCT FROM to_jsonb(operation)) AS snapshot_mismatch
  FROM public.ar_open_item_audit audit
  LEFT JOIN public.ar_open_item_operations operation
    ON operation.company_id=audit.company_id AND operation.id=audit.entity_id
  WHERE audit.entity_kind='OPERATION'
  GROUP BY audit.company_id
), allocation_stats AS (
  SELECT audit.company_id,count(*) AS audit_rows,
    count(*) FILTER(WHERE allocation.id IS NULL) AS missing_entity,
    count(*) FILTER(WHERE allocation.id IS NOT NULL
      AND audit.actor_id IS DISTINCT FROM allocation.created_by) AS actor_mismatch,
    count(*) FILTER(WHERE allocation.id IS NOT NULL
      AND audit.state_snapshot IS DISTINCT FROM to_jsonb(allocation)) AS raw_snapshot_mismatch,
    count(*) FILTER(WHERE allocation.id IS NOT NULL
      AND (audit.state_snapshot || jsonb_build_object(
        'effective_date',allocation.effective_date))
        IS DISTINCT FROM to_jsonb(allocation)) AS mismatch_after_effective_date_compat,
    count(*) FILTER(WHERE allocation.id IS NOT NULL
      AND NOT (audit.state_snapshot ? 'effective_date')) AS legacy_snapshot_without_effective_date
  FROM public.ar_open_item_audit audit
  LEFT JOIN public.ar_open_item_allocations allocation
    ON allocation.company_id=audit.company_id AND allocation.id=audit.entity_id
  WHERE audit.entity_kind='ALLOCATION'
  GROUP BY audit.company_id
), companies AS (
  SELECT company.id,company.company_code
  FROM public.companies company
  JOIN public.company_sales_process_settings process
    ON process.company_id=company.id
   AND process.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE company.status='ACTIVE'
), ledger AS (
  SELECT count(*) FILTER(WHERE version='20261105100000') AS task2,
    count(*) FILTER(WHERE version='20261105110000') AS task3,
    count(*) FILTER(WHERE version='20261106100000') AS task5,
    count(*) FILTER(WHERE version='20261110110000') AS company_date,
    count(*) FILTER(WHERE version='20261110130000') AS parity
  FROM private.kgs_schema_migrations
  WHERE version IN('20261105100000','20261105110000','20261106100000',
    '20261110110000','20261110130000')
)
SELECT 'backoffice_ar_task3_audit_lineage_failure_diagnosis' AS check_name,
  'INFO' AS status,0::bigint AS violation_rows,
  jsonb_build_object(
    'mutation','NONE',
    'ledger',jsonb_build_object('task2',max(ledger.task2),'task3',max(ledger.task3),
      'task5',max(ledger.task5),'companyDate',max(ledger.company_date),
      'parity',max(ledger.parity)),
    'companies',COALESCE(jsonb_agg(jsonb_build_object(
      'companyCode',companies.company_code,
      'registry',jsonb_build_object('auditRows',COALESCE(registry.audit_rows,0),
        'missingEntity',COALESCE(registry.missing_entity,0),
        'actorMismatch',COALESCE(registry.actor_mismatch,0),
        'snapshotMismatch',COALESCE(registry.snapshot_mismatch,0)),
      'operation',jsonb_build_object('auditRows',COALESCE(operation.audit_rows,0),
        'missingEntity',COALESCE(operation.missing_entity,0),
        'actorMismatch',COALESCE(operation.actor_mismatch,0),
        'snapshotMismatch',COALESCE(operation.snapshot_mismatch,0)),
      'allocation',jsonb_build_object('auditRows',COALESCE(allocation.audit_rows,0),
        'missingEntity',COALESCE(allocation.missing_entity,0),
        'actorMismatch',COALESCE(allocation.actor_mismatch,0),
        'rawSnapshotMismatch',COALESCE(allocation.raw_snapshot_mismatch,0),
        'legacySnapshotWithoutEffectiveDate',
          COALESCE(allocation.legacy_snapshot_without_effective_date,0),
        'mismatchAfterEffectiveDateCompat',
          COALESCE(allocation.mismatch_after_effective_date_compat,0)))
      ORDER BY companies.company_code),'[]'::jsonb)) AS details
FROM companies
LEFT JOIN registry_stats registry ON registry.company_id=companies.id
LEFT JOIN operation_stats operation ON operation.company_id=companies.id
LEFT JOIN allocation_stats allocation ON allocation.company_id=companies.id
CROSS JOIN ledger;


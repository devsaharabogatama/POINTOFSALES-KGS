-- Revision Order-date authority closing gate. SELECT-only.
WITH runtime AS (
  SELECT lower(regexp_replace(COALESCE(pg_get_functiondef(to_regprocedure(
    'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)')),''),
    '[[:space:]]+','','g')) definition
), invoice_runtime AS (
  SELECT lower(regexp_replace(COALESCE(pg_get_functiondef(to_regprocedure(
    'private.build_confirmed_order_invoice_snapshot(uuid,uuid)')),''),
    '[[:space:]]+','','g')) definition
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260904140000'
  UNION ALL
  SELECT 'revision_transient_date_runtime_contract',
    CASE WHEN position('v_date_identity:=private.resolve_sales_order_revision_date_identity('
        IN definition)>0
      AND position('v_payload:=private.sales_order_revision_identity_payload('
        IN definition)>0
      AND position('payload_snapshot=private.sales_order_revision_identity_payload('
        IN definition)>0
      AND position('order_timing_mode=v_source.order_timing_mode' IN definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('v_date_identity:=private.resolve_sales_order_revision_date_identity('
        IN definition)>0
      AND position('v_payload:=private.sales_order_revision_identity_payload('
        IN definition)>0
      AND position('payload_snapshot=private.sales_order_revision_identity_payload('
        IN definition)>0
      AND position('order_timing_mode=v_source.order_timing_mode' IN definition)>0
      THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM runtime
  UNION ALL
  SELECT 'canonical_tempo_guard_dependency',
    CASE WHEN to_regprocedure(
        'public.save_pos_sale_draft_with_pricelist(jsonb)') IS NOT NULL
      AND to_regprocedure(
        'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure(
        'public.save_pos_sale_draft_with_pricelist(jsonb)') IS NOT NULL
      AND to_regprocedure(
        'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)') IS NOT NULL
      THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('saveRoutineExists',to_regprocedure(
        'public.save_pos_sale_draft_with_pricelist(jsonb)') IS NOT NULL,
      'validatorExists',to_regprocedure(
        'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)') IS NOT NULL)
  UNION ALL
  SELECT 'confirmed_order_invoice_date_authority_contract',
    CASE WHEN position('resolve_sales_order_revision_date_identity('
        IN definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('resolve_sales_order_revision_date_identity('
        IN definition)>0
      THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM invoice_runtime
  UNION ALL
  SELECT 'private_revision_date_helper_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM (VALUES
      ('anon','private.resolve_sales_order_revision_date_identity(jsonb,text)'),
      ('authenticated','private.resolve_sales_order_revision_date_identity(jsonb,text)'),
      ('anon','private.sales_order_revision_identity_payload(jsonb,jsonb,boolean)'),
      ('authenticated','private.sales_order_revision_identity_payload(jsonb,jsonb,boolean)')
    ) candidate(role_name,routine_name)
  WHERE has_function_privilege(candidate.role_name,
    candidate.routine_name,'EXECUTE')
  UNION ALL
  SELECT 'revision_order_date_identity_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source
    ON source.company_id=revision.company_id
   AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
   AND replacement.id=revision.replacement_sales_id
  JOIN public.companies company ON company.id=revision.company_id
  WHERE revision.status IN('PENDING','APPLIED')
    AND revision.started_at>=COALESCE((SELECT migration.applied_at
      FROM private.kgs_schema_migrations migration
      WHERE migration.version='20260904140000'),clock_timestamp())
    AND (replacement.order_timing_mode IS DISTINCT FROM source.order_timing_mode
      OR replacement.planned_order_date IS DISTINCT FROM source.planned_order_date
      OR (source.order_timing_mode='SCHEDULED' AND
        (replacement.transaction_date AT TIME ZONE company.timezone)::DATE
          IS DISTINCT FROM source.planned_order_date)
      OR (source.order_timing_mode<>'SCHEDULED' AND
        replacement.transaction_date IS DISTINCT FROM source.transaction_date))
  UNION ALL
  SELECT 'pending_revision_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  WHERE revision.status='PENDING' AND (
    EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=revision.company_id
        AND reservation.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=revision.company_id
        AND invoice.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=revision.company_id
        AND event.source_id=revision.replacement_sales_id))
  UNION ALL
  SELECT 'revision_transient_date_runtime_inventory','INFO',0::BIGINT,
    jsonb_build_object('pendingRevisions',count(*) FILTER(
      WHERE status='PENDING'),'appliedRevisions',count(*) FILTER(
      WHERE status='APPLIED'))
  FROM public.sales_order_revisions
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;

-- Step 1E-B2/6 one-result, SELECT-only verification.
WITH
routine_contract AS (
  SELECT count(routine_oid)::bigint present FROM (VALUES
    (to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)')),
    (to_regprocedure('private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)')),
    (to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)')),
    (to_regprocedure('public.get_sales_process_cutover_preview(text)'))
  ) required(routine_oid)
),
previews AS MATERIALIZED (
  SELECT setting.company_id,setting.active_mode,
    private.get_sales_process_cutover_preview_core(setting.company_id,
      CASE WHEN setting.active_mode='RETAIL_CONFIRM_INVOICE'
        THEN 'BACKOFFICE_DELIVERED_QTY_INVOICE'
        ELSE 'RETAIL_CONFIRM_INVOICE' END) preview
  FROM public.company_sales_process_settings setting
),
candidates AS MATERIALIZED (
  SELECT preview.company_id,preview.active_mode,candidate.value candidate
  FROM previews preview
  CROSS JOIN LATERAL jsonb_array_elements(preview.preview->'candidates') candidate(value)
),
checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910152000'
  UNION ALL
  SELECT 'payment_term_boundary_routine_contract',
    CASE WHEN present=4 THEN 'PASS' ELSE 'FAIL' END,(4-present)::bigint,
    jsonb_build_object('expected',4,'present',present) FROM routine_contract
  UNION ALL
  SELECT 'payment_term_classifier_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.routine_schema='private'
    AND privilege.routine_name='classify_sales_process_conversion_candidate'
    AND privilege.grantee IN('anon','authenticated') AND privilege.privilege_type='EXECUTE'
  UNION ALL
  SELECT 'payment_term_preview_version_contract',
    CASE WHEN count(*) FILTER(WHERE (preview->>'previewVersion')::integer<>2)=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE (preview->>'previewVersion')::integer<>2)::bigint,
    jsonb_build_object('companyPreviews',count(*),'expectedVersion',2)
  FROM previews
  UNION ALL
  SELECT 'multi_installment_preview_blocker_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM candidates
  WHERE COALESCE((candidate->'facts'->>'hasMultiInstallmentPaymentTerm')::boolean,false)
    AND (candidate->>'decision'<>'BLOCKED'
      OR NOT (candidate->'blockerCodes' ? 'MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE'))
  UNION ALL
  SELECT 'single_absolute_due_date_requirement_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM candidates
  WHERE candidate->>'decision'='CONVERT'
    AND COALESCE((candidate->'facts'->>'isTempo')::boolean,false)
    AND NOT (candidate->'requirementCodes' ? 'PRESERVE_SINGLE_ABSOLUTE_DUE_DATE')
  UNION ALL
  SELECT 'payment_term_preview_fact_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM candidates
  WHERE NOT (candidate->'facts' ? 'isTempo')
    OR NOT (candidate->'facts' ? 'legacyDueDate')
    OR NOT (candidate->'facts' ? 'paymentTermShape')
    OR NOT (candidate->'facts' ? 'hasMultiInstallmentPaymentTerm')
  UNION ALL
  SELECT 'payment_term_boundary_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('companyPreviews',count(DISTINCT company_id),
      'candidates',count(*),
      'tempoConvertible',count(*) FILTER(WHERE candidate->>'decision'='CONVERT'
        AND COALESCE((candidate->'facts'->>'isTempo')::boolean,false)),
      'multiInstallmentBlocked',count(*) FILTER(WHERE candidate->>'decision'='BLOCKED'
        AND candidate->'blockerCodes' ? 'MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE'))
  FROM candidates
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;


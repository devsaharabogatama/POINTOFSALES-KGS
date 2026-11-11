-- READ ONLY. Run after 20261110100000 and after rollback-only behavior.
BEGIN READ ONLY;

WITH ledger AS (
  SELECT count(*) ledger_rows
  FROM private.kgs_schema_migrations
  WHERE version='20261110100000'
), schema_contract AS (
  SELECT
    (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public'
        AND table_name='backoffice_sales_invoices'
        AND column_name IN(
          'replacement_credit_note_id','replacement_source_invoice_id')) header_columns,
    (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public'
        AND table_name='backoffice_sales_invoice_lines'
        AND column_name='replacement_source_invoice_line_id') line_columns,
    (SELECT count(*) FROM pg_indexes
      WHERE schemaname='public'
        AND indexname='backoffice_sales_invoices_replacement_note_unique') unique_indexes
), runtime_contract AS (
  SELECT
    to_regprocedure(
      'public.post_backoffice_credit_note_create_replacement_invoice(uuid,bigint,uuid)') IS NOT NULL combined_rpc,
    to_regprocedure(
      'public.get_backoffice_credit_note_replacement(uuid)') IS NOT NULL read_rpc,
    to_regprocedure(
      'private.save_backoffice_replacement_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)') IS NOT NULL replacement_save,
    pg_get_functiondef(
      'public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)'::regprocedure)
      ILIKE '%replacement_credit_note_id%' save_dispatch,
    (length(pg_get_functiondef(
      'private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid)'::regprocedure))
      -length(replace(pg_get_functiondef(
        'private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid)'::regprocedure),
        'IF v_invoice.invoice_type=''REGULAR'' AND v_invoice.replacement_credit_note_id IS NULL THEN','')))
      /length(
        'IF v_invoice.invoice_type=''REGULAR'' AND v_invoice.replacement_credit_note_id IS NULL THEN')=2
      post_replacement_aware
), data_contract AS (
  SELECT
    count(*) FILTER(WHERE invoice.replacement_credit_note_id IS NOT NULL
      AND (invoice.replacement_source_invoice_id IS NULL
        OR invoice.invoice_type<>'REGULAR'
        OR invoice.company_id<>note.company_id
        OR note.source_invoice_id<>invoice.replacement_source_invoice_id
        OR invoice.customer_id<>note.customer_id)) invalid,
    count(*) FILTER(
      WHERE invoice.replacement_credit_note_id IS NOT NULL) replacement_rows
  FROM public.backoffice_sales_invoices invoice
  LEFT JOIN public.backoffice_sales_credit_notes note
    ON note.company_id=invoice.company_id
    AND note.id=invoice.replacement_credit_note_id
), privilege_contract AS (
  SELECT
    has_function_privilege('authenticated',
      'public.post_backoffice_credit_note_create_replacement_invoice(uuid,bigint,uuid)',
      'EXECUTE') combined_authenticated,
    has_function_privilege('authenticated',
      'public.get_backoffice_credit_note_replacement(uuid)',
      'EXECUTE') read_authenticated,
    has_function_privilege('authenticated',
      'private.create_backoffice_replacement_invoice_draft(uuid,uuid,uuid,uuid)',
      'EXECUTE') helper_authenticated,
    has_table_privilege(
      'authenticated','public.ar_open_item_registry','SELECT') direct_registry_select
), checks AS (
  SELECT 1 ordinal,
    'backoffice_ar_credit_note_replacement_postflight_migration_ledger'::text check_name,
    CASE WHEN ledger_rows=1 THEN 'PASS' ELSE 'FAIL' END::text status,
    abs(1-ledger_rows)::bigint violation_rows,
    jsonb_build_object('ledgerRows',ledger_rows) details
  FROM ledger

  UNION ALL

  SELECT 2,
    'backoffice_ar_credit_note_replacement_postflight_schema_contract',
    CASE WHEN header_columns=2 AND line_columns=1 AND unique_indexes=1
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN header_columns=2 AND line_columns=1 AND unique_indexes=1
      THEN 0 ELSE 1 END,
    to_jsonb(schema_contract)
  FROM schema_contract

  UNION ALL

  SELECT 3,
    'backoffice_ar_credit_note_replacement_postflight_runtime_contract',
    CASE WHEN combined_rpc AND read_rpc AND replacement_save AND save_dispatch
        AND post_replacement_aware THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN combined_rpc AND read_rpc AND replacement_save AND save_dispatch
        AND post_replacement_aware THEN 0 ELSE 1 END,
    to_jsonb(runtime_contract)
  FROM runtime_contract

  UNION ALL

  SELECT 4,
    'backoffice_ar_credit_note_replacement_postflight_data_contract',
    CASE WHEN invalid=0 THEN 'PASS' ELSE 'FAIL' END,
    invalid,
    jsonb_build_object(
      'invalidRows',invalid,'replacementDrafts',replacement_rows)
  FROM data_contract

  UNION ALL

  SELECT 5,
    'backoffice_ar_credit_note_replacement_postflight_privilege_contract',
    CASE WHEN combined_authenticated AND read_authenticated
        AND NOT helper_authenticated AND NOT direct_registry_select
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN combined_authenticated AND read_authenticated
        AND NOT helper_authenticated AND NOT direct_registry_select
      THEN 0 ELSE 1 END,
    to_jsonb(privilege_contract)
  FROM privilege_contract

  UNION ALL

  SELECT 6,
    'backoffice_ar_credit_note_replacement_postflight_business_boundary',
    'INFO',0,
    jsonb_build_object(
      'next','Run rollback-only behavior, static client tests, then authenticated local smoke',
      'changed',ARRAY[
        'atomic native Credit Note post/source allocation/replacement Draft',
        'replacement Draft edit and later normal Finance post'],
      'preserved',ARRAY['plain Credit Note post',
        'ordinary Invoice quantity allocation','POS and retained Retail',
        'Dispatch/Stock/FIFO/HPP','historical settlement and Journals'])
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY ordinal;

ROLLBACK;

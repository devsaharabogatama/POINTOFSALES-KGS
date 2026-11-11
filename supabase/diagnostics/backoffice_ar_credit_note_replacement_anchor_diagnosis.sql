-- READ ONLY. Diagnose the exact Task 6 runtime anchor that differs.
-- Run only after the Task 6 migration has failed closed.
WITH expected(signature, expected_md5) AS (
  VALUES
    ('public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)',
      '91a423d2fb08901b7596f3b048c84cd2'),
    ('private.ar3_post_backoffice_sales_invoice_core(uuid,bigint,uuid)',
      'c874b7d081b9781004eaf42522bda1d0'),
    ('private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)',
      '3ce005460e7e50ec4b9d9134e5e4a928'),
    ('public.post_backoffice_sales_credit_note(uuid,bigint,uuid)',
      '93723ceab34fd6318088f314e976dd72'),
    ('public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)',
      '1f3eb44dda2997282789da828e31fa81')
), inventory AS (
  SELECT signature, expected_md5, to_regprocedure(signature) routine
  FROM expected
), comparison AS (
  SELECT signature, expected_md5, routine,
    CASE WHEN routine IS NULL THEN NULL
      ELSE md5(pg_get_functiondef(routine)) END actual_md5
  FROM inventory
)
SELECT
  'backoffice_ar_credit_note_replacement_anchor_diagnosis' check_name,
  CASE WHEN count(*) FILTER (
      WHERE routine IS NULL OR actual_md5 IS DISTINCT FROM expected_md5)=0
    THEN 'PASS' ELSE 'ROOT_CAUSE' END status,
  count(*) FILTER (
    WHERE routine IS NULL OR actual_md5 IS DISTINCT FROM expected_md5) violation_rows,
  jsonb_build_object(
    'task6LedgerRows',(SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261110100000'),
    'anchors',jsonb_agg(jsonb_build_object(
      'signature',signature,
      'exists',routine IS NOT NULL,
      'expectedMd5',expected_md5,
      'actualMd5',actual_md5,
      'matches',routine IS NOT NULL AND actual_md5=expected_md5)
      ORDER BY signature),
    'mutation','NONE') details
FROM comparison;

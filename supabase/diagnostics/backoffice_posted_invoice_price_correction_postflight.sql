-- Read-only postflight for migration 20260928110000.
DROP TABLE IF EXISTS pg_temp.backoffice_invoice_price_correction_postflight_result;
CREATE TEMP TABLE backoffice_invoice_price_correction_postflight_result(
  check_name text,status text,violation_rows bigint,details jsonb
);

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
  abs(1-count(*)),jsonb_build_object('ledgerRows',count(*)) FROM private.kgs_schema_migrations
WHERE version='20260928110000';

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_relation_contract',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
  3-count(*),jsonb_build_object('present',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb),'expected',3)
FROM (SELECT name FROM (VALUES
  ('backoffice_sales_invoice_price_corrections'),('backoffice_sales_invoice_price_correction_lines'),
  ('backoffice_sales_invoice_price_correction_operations')) expected(name)
  WHERE to_regclass('public.'||name) IS NOT NULL) present;

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_routine_contract',CASE WHEN count(*)=9 THEN 'PASS' ELSE 'FAIL' END,
  9-count(*),jsonb_build_object('present',COALESCE(jsonb_agg(signature ORDER BY signature),'[]'::jsonb),'expected',9)
FROM (SELECT signature FROM (VALUES
  ('private.backoffice_invoice_price_delta(uuid,uuid,date)'),
  ('private.backoffice_invoice_effective_total(uuid,uuid,date)'),
  ('private.backoffice_invoice_effective_entered_unit_price(uuid,uuid)'),
  ('private.backoffice_invoice_effective_line_amounts(uuid,uuid)'),
  ('private.rebuild_backoffice_invoice_effective_schedules(uuid,uuid)'),
  ('private.backoffice_sales_invoice_ui_snapshot_before_price_correction(uuid,uuid)'),
  ('private.backoffice_sales_invoice_ui_snapshot(uuid,uuid)'),
  ('public.get_backoffice_sales_invoice_price_correction_context(uuid)'),
  ('public.post_backoffice_sales_invoice_price_correction(uuid,bigint,bigint,uuid,jsonb)')) expected(signature)
  WHERE to_regprocedure(signature) IS NOT NULL) present;

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_schedule_column',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
  abs(1-count(*)),jsonb_build_object('rows',count(*),'notNull',bool_and(is_nullable='NO'))
FROM information_schema.columns WHERE table_schema='public'
  AND table_name='backoffice_sales_invoice_receivable_schedules' AND column_name='original_amount_due';

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_immutability_trigger',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
  2-count(*),jsonb_build_object('rows',count(*),'enabled',count(*) FILTER(WHERE tgenabled='O'))
FROM pg_trigger WHERE NOT tgisinternal AND tgname IN(
  'backoffice_invoice_price_corrections_immutable','backoffice_invoice_price_correction_lines_immutable');

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_debit_note_catalog',
  CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
  jsonb_build_object('rows',count(*),'requiredConditional','CUSTOMER_REFUND_LIABILITY')
FROM public.system_events event WHERE event.system_key='CUSTOMER_DEBIT_NOTE'
  AND event.conditional_account_functions @> ARRAY['CUSTOMER_REFUND_LIABILITY']::text[];

DO $runtime$
DECLARE v_post text;v_return text;v_statement text;v_receipt text;v_receipt_workspace text;
BEGIN
  SELECT pg_get_functiondef('public.post_backoffice_sales_invoice_price_correction(uuid,bigint,bigint,uuid,jsonb)'::regprocedure) INTO STRICT v_post;
  SELECT pg_get_functiondef('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)'::regprocedure) INTO STRICT v_return;
  SELECT pg_get_functiondef('public.get_finance_customer_statement(uuid,date,date,uuid)'::regprocedure) INTO STRICT v_statement;
  SELECT pg_get_functiondef('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::regprocedure) INTO STRICT v_receipt;
  SELECT pg_get_functiondef('public.get_finance_customer_receipts()'::regprocedure) INTO STRICT v_receipt_workspace;
  INSERT INTO backoffice_invoice_price_correction_postflight_result VALUES(
    'posted_invoice_price_correction_runtime_definition',
    CASE WHEN v_post LIKE '%INVOICE_PRICE_REVISION_CONFLICT%'
      AND v_post LIKE '%INVOICE_PRICE_CORRECTION_AFTER_RETURN_NOT_ALLOWED%'
      AND v_post LIKE '%source_kind=''SALES_ORDER''%'
      AND v_return LIKE '%backoffice_invoice_effective_line_amounts%'
      AND v_return LIKE '%priceCorrectionRevision%'
      AND v_statement LIKE '%backoffice_sales_invoice_price_corrections%'
      AND v_receipt LIKE '%backoffice_invoice_receivable_before_receipts%'
      AND v_receipt_workspace LIKE '%backoffice_invoice_effective_total(invoice.company_id,invoice.id,v_today)%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN v_post LIKE '%INVOICE_PRICE_REVISION_CONFLICT%'
      AND v_post LIKE '%INVOICE_PRICE_CORRECTION_AFTER_RETURN_NOT_ALLOWED%'
      AND v_post LIKE '%source_kind=''SALES_ORDER''%'
      AND v_return LIKE '%backoffice_invoice_effective_line_amounts%'
      AND v_return LIKE '%priceCorrectionRevision%'
      AND v_statement LIKE '%backoffice_sales_invoice_price_corrections%'
      AND v_receipt LIKE '%backoffice_invoice_receivable_before_receipts%'
      AND v_receipt_workspace LIKE '%backoffice_invoice_effective_total(invoice.company_id,invoice.id,v_today)%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('required',ARRAY['stale price revision','existing Return Credit guard',
      'Sales Order lines only','future Return effective price','Customer Statement correction row',
      'Receipt effective cap','Receipt workspace effective total']));
END
$runtime$;

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_finance_reconciliation',CASE WHEN count(*) FILTER(WHERE invalid)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*) FILTER(WHERE invalid),jsonb_build_object('invalidRows',count(*) FILTER(WHERE invalid))
FROM (SELECT correction.id,
  correction.total_delta<>round(COALESCE((SELECT sum(line.total_delta)
    FROM public.backoffice_sales_invoice_price_correction_lines line
    WHERE line.company_id=correction.company_id AND line.correction_id=correction.id),0),4)
  OR correction.total_delta<>correction.ar_adjustment_amount-correction.refund_liability_amount
  OR COALESCE((correction.source_invoice_snapshot->'priceCorrectionSettlement'->>'arAdjustmentAmount')::numeric,0)
      <>correction.ar_adjustment_amount
  OR COALESCE((correction.source_invoice_snapshot->'priceCorrectionSettlement'->>'refundLiabilityAmount')::numeric,0)
      <>correction.refund_liability_amount
  OR event.status<>'POSTED'::public.event_status OR journal.status<>'POSTED'
  OR round(journal.total_debit,4)<>round(journal.total_credit,4) invalid
  FROM public.backoffice_sales_invoice_price_corrections correction
  LEFT JOIN public.financial_events event ON event.company_id=correction.company_id
    AND event.id=correction.financial_event_id
  LEFT JOIN public.finance_journals journal ON journal.company_id=correction.company_id
    AND journal.financial_event_id=correction.financial_event_id) audit;

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_schedule_reconciliation',CASE WHEN count(*) FILTER(WHERE invalid)=0 THEN 'PASS' ELSE 'FAIL' END,
  count(*) FILTER(WHERE invalid),jsonb_build_object('invalidRows',count(*) FILTER(WHERE invalid))
FROM (SELECT invoice.id,round(COALESCE(sum(schedule.amount_due),0),4)
      <>round(private.backoffice_invoice_effective_total(invoice.company_id,invoice.id,NULL),4) invalid
  FROM public.backoffice_sales_invoices invoice
  JOIN public.backoffice_sales_invoice_price_corrections correction ON correction.company_id=invoice.company_id
    AND correction.source_invoice_id=invoice.id AND correction.status='POSTED'
  LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule ON schedule.company_id=invoice.company_id
    AND schedule.invoice_id=invoice.id
  WHERE invoice.status='POSTED' GROUP BY invoice.company_id,invoice.id) audit;

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_permission_contract',
  CASE WHEN has_authenticated AND NOT has_private_authenticated THEN 'PASS' ELSE 'FAIL' END,
  (NOT has_authenticated)::int+has_private_authenticated::int,
  jsonb_build_object('publicAuthenticated',has_authenticated,'privateAuthenticated',has_private_authenticated)
FROM (SELECT
  has_function_privilege('authenticated','public.post_backoffice_sales_invoice_price_correction(uuid,bigint,bigint,uuid,jsonb)','EXECUTE') has_authenticated,
  has_function_privilege('authenticated','private.backoffice_invoice_effective_total(uuid,uuid,date)','EXECUTE') has_private_authenticated) permission;

INSERT INTO backoffice_invoice_price_correction_postflight_result
SELECT 'posted_invoice_price_correction_runtime_inventory','INFO',0,jsonb_build_object(
  'postedCorrections',count(*),'debitNotes',count(*) FILTER(WHERE correction_kind='DEBIT_NOTE'),
  'creditNotes',count(*) FILTER(WHERE correction_kind='CREDIT_NOTE'),
  'refundLiabilityAmount',COALESCE(sum(refund_liability_amount),0))
FROM public.backoffice_sales_invoice_price_corrections;

SELECT check_name,status,violation_rows,details
FROM backoffice_invoice_price_correction_postflight_result ORDER BY check_name;

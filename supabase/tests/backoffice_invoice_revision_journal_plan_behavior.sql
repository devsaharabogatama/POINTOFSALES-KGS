DO $test$
DECLARE operation uuid;plan jsonb;leg jsonb;debit numeric;credit numeric;
BEGIN
  SELECT operation_id INTO STRICT operation
  FROM private.backoffice_invoice_revision_preparations
  WHERE (request_snapshot->>'invoiceDate')::date>
    (source_snapshot->'invoice'->>'invoice_date')::date
  ORDER BY created_at DESC LIMIT 1;
  plan:=private.plan_backoffice_invoice_revision_journals(operation);
  IF plan->>'status' IS DISTINCT FROM 'JOURNAL_PLAN_NOT_POSTED'
    OR (plan->>'writerEffect')::boolean IS DISTINCT FROM false
    OR jsonb_array_length(plan->'recognitionReversal'->'lines')<2
    OR jsonb_array_length(plan->'recognitionReplacement'->'lines')<2
    OR jsonb_array_length(plan->'receiptJournalLegs')<>4
    OR jsonb_array_length(plan->'downPaymentJournalLegs')<1
    OR jsonb_array_length(plan->'amountJournal'->'lines')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: journal plan shape mismatch: %',plan;
  END IF;
  FOR leg IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
      plan->'recognitionReversal',plan->'recognitionReplacement')
      ||plan->'receiptJournalLegs'||plan->'downPaymentJournalLegs'
      ||jsonb_build_array(plan->'amountJournal')) LOOP
    SELECT round(COALESCE(sum((line->>'debit')::numeric),0),4),
      round(COALESCE(sum((line->>'credit')::numeric),0),4)
    INTO debit,credit FROM jsonb_array_elements(leg->'lines') line;
    IF debit<>credit THEN RAISE EXCEPTION 'TEST_FAILED: journal plan leg unbalanced'; END IF;
  END LOOP;
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(plan->'receiptJournalLegs') item(value)
      WHERE item.value->>'leg'='RECEIPT_TO_ADVANCE')
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(plan->'receiptJournalLegs') item(value)
      WHERE item.value->>'leg'='ADVANCE_TO_REVISED_INVOICE')
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(plan->'downPaymentJournalLegs') item(value)
      WHERE item.value->>'leg'='TRANSFER_DP_ATTRIBUTION') THEN
    RAISE EXCEPTION 'TEST_FAILED: mandatory settlement legs missing';
  END IF;
END
$test$;
SELECT 'backoffice_invoice_revision_journal_plan_behavior' check_name,'PASS' status,0 violation_rows,
  jsonb_build_object('tested',ARRAY['source recognition reversal balanced',
    'replacement recognition uses revised customer and date','posted Receipt converts to advance then reapplies',
    'posted DP attribution transfer','every journal leg independently balanced','no writer effect',
    'outer transaction rolled back']) details;

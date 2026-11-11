-- Backoffice AR forward-fix: make the Task 4 shared Credit Note allocation
-- helper understand append-only reversals introduced by Task 5.
DO $guard$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(
    '20261110130000:backoffice_ar_reversal_consumer_parity',0));
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20261105100000','20261105110000','20261105120000',
      '20261106100000','20261110100000'))<>5 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice AR dependency chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261110130000';
  END IF;
  IF md5(pg_get_functiondef(
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)'::regprocedure))
        <>'97600ce6d46ae08b7df414c271fe46aa'
    OR md5(pg_get_functiondef(
      'private.ar5_item_allocated(uuid,uuid,date)'::regprocedure))
        <>'3de3fd3ba6aa98e79db22ef32f1bd0da' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AR allocation helper anchor changed';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.ar4_backoffice_invoice_allocated_credit(
  p_company_id uuid,p_invoice_id uuid,p_as_of date
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT round(COALESCE(sum(CASE
    WHEN allocation.reversal_of_allocation_id IS NULL
      THEN allocation.allocated_amount ELSE -allocation.allocated_amount END),0),4)
  FROM public.ar_open_item_registry debit_item
  JOIN public.ar_open_item_allocations allocation
    ON allocation.company_id=debit_item.company_id
    AND allocation.debit_item_id=debit_item.id
  JOIN public.ar_open_item_registry credit_item
    ON credit_item.company_id=allocation.company_id
    AND credit_item.id=allocation.credit_item_id
    AND credit_item.scope_kind='BACKOFFICE'
    AND credit_item.item_kind='CREDIT_NOTE'
    AND credit_item.direction='CREDIT'
  WHERE debit_item.company_id=p_company_id
    AND debit_item.scope_kind='BACKOFFICE'
    AND debit_item.item_kind='INVOICE'
    AND debit_item.direction='DEBIT'
    AND debit_item.source_id=p_invoice_id
    AND (p_as_of IS NULL OR COALESCE(
      allocation.effective_date,credit_item.document_date)<=p_as_of)
$$;

REVOKE ALL ON FUNCTION
  private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)
  TO service_role;

DO $postcondition$
DECLARE v_invalid bigint;
BEGIN
  IF pg_get_functiondef(
      'private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)'::regprocedure)
      NOT ILIKE '%reversal_of_allocation_id%' THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: helper is not reversal aware';
  END IF;
  SELECT count(*) INTO v_invalid
  FROM public.ar_open_item_registry debit
  WHERE debit.scope_kind='BACKOFFICE' AND debit.item_kind='INVOICE'
    AND debit.direction='DEBIT'
    AND private.ar4_backoffice_invoice_allocated_credit(
      debit.company_id,debit.source_id,NULL)<>(SELECT round(COALESCE(sum(CASE
        WHEN allocation.reversal_of_allocation_id IS NULL
          THEN allocation.allocated_amount ELSE -allocation.allocated_amount END),0),4)
      FROM public.ar_open_item_allocations allocation
      JOIN public.ar_open_item_registry credit ON credit.company_id=allocation.company_id
        AND credit.id=allocation.credit_item_id AND credit.scope_kind='BACKOFFICE'
        AND credit.item_kind='CREDIT_NOTE' AND credit.direction='CREDIT'
      WHERE allocation.company_id=debit.company_id
        AND allocation.debit_item_id=debit.id);
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: AR helper parity %',v_invalid;
  END IF;
END
$postcondition$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261110130000','backoffice_ar_reversal_consumer_parity',
  'Forward-fix Task 4 shared Backoffice Credit Note allocation helper to net Task 5 append-only reversals; AR reports/workspace/payment/schedule/revision consumers align without Journal, Stock, POS or historical row mutation');

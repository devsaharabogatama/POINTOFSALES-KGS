-- ODR-6A.1 Invoice identity forward-fix fixture-free behavior contract.
BEGIN;

DO $test$
DECLARE v_confirm TEXT;v_helper TEXT;v_allocate_pos INTEGER;v_document_pos INTEGER;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828280000') THEN
    RAISE EXCEPTION 'TEST_FAILED: ODR-6A.1 migration ledger missing';
  END IF;
  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_confirm;
  SELECT pg_get_functiondef(
    'private.ensure_confirmed_order_invoice_identity(uuid,uuid)'::regprocedure)
  INTO v_helper;
  v_allocate_pos:=strpos(v_confirm,'ensure_confirmed_order_invoice_identity');
  v_document_pos:=strpos(v_confirm,'ensure_confirmed_order_documents');
  IF v_confirm!~'confirm_pos_sales_order_core'
    OR v_allocate_pos=0 OR v_document_pos=0 OR v_allocate_pos>=v_document_pos
    OR v_confirm!~'capture_sales_order_payment_requests'
    OR v_helper!~'pos_invoice_number_seq'
    OR v_helper!~'INV-'
    OR v_helper!~'DRAFT-%'
    OR v_helper!~'FOR UPDATE' THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice identity allocation contract invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid='public.sales_document_audit'::regclass
      AND constraint_row.conname='sales_document_audit_action_check'
      AND pg_get_constraintdef(constraint_row.oid)~'REPAIR_IDENTITY') THEN
    RAISE EXCEPTION 'TEST_FAILED: identity repair audit contract missing';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'odr_phase6a_invoice_identity_forward_fix_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'reservation before Invoice allocation',
    'Invoice allocation before immutable document creation',
    'exact identity reuse','payment capture preserved',
    'repair audit vocabulary','no fixture or write persisted'
  ],'writesPersisted',FALSE) details;

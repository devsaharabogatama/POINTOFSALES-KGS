-- Transactional behavioral test. It rolls back all attempted changes.
BEGIN;

DO $test$
DECLARE
  v_sale public.sales_headers%ROWTYPE;
  v_blocked BOOLEAN:=FALSE;
BEGIN
  SELECT * INTO v_sale FROM public.sales_headers ORDER BY created_at,id LIMIT 1;
  IF v_sale.id IS NULL THEN
    RAISE EXCEPTION 'TEST_SETUP_REQUIRED: one existing Sale is required';
  END IF;
  IF v_sale.sales_origin<>'POS'
    OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE' THEN
    RAISE EXCEPTION 'TEST_FAILED: existing Sale identity backfill invalid';
  END IF;

  BEGIN
    UPDATE public.sales_headers
    SET sales_origin='BACKOFFICE_SALES',
        sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    WHERE id=v_sale.id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%SALES_PROCESS_IDENTITY_IMMUTABLE%' THEN
      v_blocked:=TRUE;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: process identity mutation was accepted';
  END IF;

  IF EXISTS(SELECT 1 FROM public.company_features
      WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_enabled) THEN
    RAISE EXCEPTION 'TEST_FAILED: foundation enabled a Company';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'backoffice_sales_process_identity_behavior'::text check_name,
  'PASS'::text status,0::bigint violation_rows,
  jsonb_build_object(
    'existingIdentity','POS + RETAIL_CONFIRM_INVOICE',
    'identityMutationBlocked',true,
    'transactionRolledBack',true,
    'note','This test does not create Backoffice orders or final effects') details;

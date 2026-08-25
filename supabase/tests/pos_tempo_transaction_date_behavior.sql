-- Authenticated read behavior for POS TEMPO date support. No mutation.
BEGIN;

DO $fixture$
DECLARE v_actor UUID;v_company UUID;
BEGIN
  SELECT session.cashier_id,session.company_id INTO v_actor,v_company
  FROM public.cashier_sessions session
  JOIN public.companies company ON company.id=session.company_id
  WHERE session.status='OPEN'::public.session_status
    AND company.status='ACTIVE'
  ORDER BY session.opened_at DESC,session.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: open Cashier session required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'POS') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;
  PERFORM set_config('tempo_date_test.actor',v_actor::TEXT,TRUE);
END
$fixture$;

SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',current_setting('tempo_date_test.actor'),'role','authenticated'
)::TEXT,TRUE);
SET LOCAL ROLE authenticated;

DO $behavior$
DECLARE v_customers JSONB;v_drafts JSONB;
BEGIN
  v_customers:=public.get_pos_customer_references();
  IF EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_customers) customer
    WHERE NOT (customer ? 'credit_limit')
      OR NOT (customer ? 'credit_term_days')
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer credit terms are incomplete';
  END IF;

  v_drafts:=public.list_pos_sale_drafts(NULL);
  IF EXISTS(
    SELECT 1 FROM jsonb_array_elements(v_drafts) draft
    WHERE NOT (draft ? 'transactionAt') OR draft->>'transactionAt' IS NULL
  ) THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft transaction date is incomplete';
  END IF;
END
$behavior$;

RESET ROLE;
ROLLBACK;

SELECT 'pos_tempo_transaction_date_behavior' AS check_name,'PASS' AS status,
  jsonb_build_object('writesExecuted',FALSE) AS details;

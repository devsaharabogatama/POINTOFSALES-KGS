-- Retail POS Session Summary Return/refund net read model.
-- Additive and read-only: no Return, Stock, Payment, Finance or Session mutation.
BEGIN;
SET LOCAL lock_timeout='5s';

DO $guard$
DECLARE v_close_definition text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations ledger
      WHERE ledger.version IN('20260803010000','20260805130000',
      '20260813050000','20261102100000','20261102120000',
      '20261102140000'))<>6 THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Retail Return/session dependency chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
      WHERE ledger.version='20261102150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261102150000';
  END IF;
  IF to_regprocedure(
      'public.get_pos_cashier_session_return_adjustments(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Session Return adjustment RPC collision';
  END IF;
  IF to_regclass('public.sales_return_documents') IS NULL
    OR to_regclass('public.sales_return_lines') IS NULL
    OR to_regclass('public.sales_return_refunds') IS NULL
    OR to_regclass('public.company_sales_process_settings') IS NULL THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: active Return/process runtime incomplete';
  END IF;
  SELECT pg_get_functiondef(
    'private.calculate_cashier_session_expected_cash(uuid,uuid)'::regprocedure)
    INTO v_close_definition;
  IF v_close_definition NOT LIKE '%sales_return_refunds%'
    OR v_close_definition NOT LIKE
      '%document.executing_session_id=session.id%'
    OR v_close_definition NOT LIKE
      '%refund.payment_method_type_snapshot=''CASH''%' THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: close-session Return Cash contract changed';
  END IF;
  IF has_table_privilege('authenticated',
      'public.sales_return_documents','SELECT')
    OR has_table_privilege('authenticated',
      'public.sales_return_lines','SELECT')
    OR has_table_privilege('authenticated',
      'public.sales_return_refunds','SELECT') THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Return table privilege boundary changed';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_pos_cashier_session_return_adjustments(
  p_cashier_session_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_actor uuid:=auth.uid();
  v_session public.cashier_sessions%rowtype;
  v_mode text;
  v_refunds jsonb;
  v_lines jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_cashier_session_id IS NULL THEN
    RAISE EXCEPTION 'CASHIER_SESSION_REQUIRED';
  END IF;

  SELECT session.* INTO v_session
  FROM public.cashier_sessions session
  WHERE session.company_id=v_company
    AND session.id=p_cashier_session_id
    AND session.cashier_id=v_actor;
  IF NOT FOUND THEN RAISE EXCEPTION 'CASHIER_SESSION_NOT_OWNED'; END IF;

  SELECT setting.active_mode INTO v_mode
  FROM public.company_sales_process_settings setting
  WHERE setting.company_id=v_company;
  IF v_mode IS DISTINCT FROM 'RETAIL_CONFIRM_INVOICE' THEN
    RETURN jsonb_build_object(
      'companyId',v_company,
      'cashierSessionId',v_session.id,
      'processMode',v_mode,
      'applicable',false,
      'refunds','[]'::jsonb,
      'lines','[]'::jsonb
    );
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',refund.id,
      'documentId',document.id,
      'returnNo',document.return_no,
      'sourceSalesId',document.source_sales_id,
      'paymentMethodId',refund.payment_method_id,
      'paymentMethodName',refund.payment_method_name_snapshot,
      'paymentMethodType',refund.payment_method_type_snapshot,
      'settlementRoute',refund.settlement_route_snapshot,
      'amount',refund.amount
    ) ORDER BY refund.created_at,refund.id),'[]'::jsonb)
  INTO v_refunds
  FROM public.sales_return_refunds refund
  JOIN public.sales_return_documents document
    ON document.company_id=refund.company_id
   AND document.id=refund.document_id
   AND document.status='POSTED'
  JOIN public.sales_headers source_sale
    ON source_sale.company_id=document.company_id
   AND source_sale.id=document.source_sales_id
   AND source_sale.sales_origin='POS'
   AND source_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
  WHERE refund.company_id=v_company
    AND document.executing_session_id=v_session.id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'key',line.id,
      'documentId',document.id,
      'returnNo',document.return_no,
      'sourceSalesId',document.source_sales_id,
      'productId',line.product_id,
      'productName',line.product_name_snapshot,
      'productSku',line.product_sku_snapshot,
      'uomName',line.sale_uom_name_snapshot,
      'quantity',line.quantity_uom,
      'returnCondition',line.return_condition
    ) ORDER BY line.created_at,line.id),'[]'::jsonb)
  INTO v_lines
  FROM public.sales_return_lines line
  JOIN public.sales_return_documents document
    ON document.company_id=line.company_id
   AND document.id=line.document_id
   AND document.status='POSTED'
  JOIN public.sales_headers source_sale
    ON source_sale.company_id=document.company_id
   AND source_sale.id=document.source_sales_id
   AND source_sale.sales_origin='POS'
   AND source_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
  WHERE line.company_id=v_company
    AND document.executing_session_id=v_session.id;

  RETURN jsonb_build_object(
    'companyId',v_company,
    'cashierSessionId',v_session.id,
    'processMode',v_mode,
    'applicable',true,
    'refunds',v_refunds,
    'lines',v_lines
  );
END
$$;

COMMENT ON FUNCTION public.get_pos_cashier_session_return_adjustments(uuid) IS
  'Read-only net adjustment snapshots for the authenticated cashier own Retail POS session; Backoffice process and non-POS source Sales are excluded.';

REVOKE ALL ON FUNCTION
  public.get_pos_cashier_session_return_adjustments(uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.get_pos_cashier_session_return_adjustments(uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261102150000','pos_retail_session_net_return_summary',
  'Adds an own-session Retail POS-only read model for Posted Return refund and physical quantity adjustments; Backoffice and all mutation runtimes remain unchanged');

NOTIFY pgrst,'reload schema';
COMMIT;

BEGIN;

DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260825100000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260825100000';
  END IF;
  IF to_regprocedure(
    'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)'
  ) IS NULL
     OR to_regclass('public.cashier_sessions') IS NULL
     OR to_regclass('public.customers') IS NULL
     OR to_regclass('public.products') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical POS pricing runtime missing';
  END IF;
END
$guard$;

CREATE FUNCTION public.preview_pos_sale_prices(
  p_cashier_session_id UUID,
  p_customer_id UUID,
  p_selected_pricelist_id UUID,
  p_lines JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_session public.cashier_sessions%ROWTYPE;
  v_resolved_at TIMESTAMPTZ:=clock_timestamp();
  v_line JSONB;
  v_line_key TEXT;
  v_product_uom_id UUID;
  v_quantity NUMERIC;
  v_price JSONB;
  v_product_sku TEXT;
  v_lines JSONB:='[]'::JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_lines)=0
     OR jsonb_array_length(p_lines)>1000 THEN
    RAISE EXCEPTION 'PRICE_PREVIEW_LINES_INVALID';
  END IF;

  SELECT * INTO v_session
  FROM public.cashier_sessions session
  WHERE session.company_id=v_company
    AND session.id=p_cashier_session_id
    AND session.cashier_id=v_actor
    AND session.status='OPEN'::public.session_status;
  IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;

  IF p_customer_id IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.customers customer
    WHERE customer.company_id=v_company
      AND customer.id=p_customer_id
      AND customer.is_active
  ) THEN
    RAISE EXCEPTION 'ACTIVE_CUSTOMER_NOT_FOUND';
  END IF;

  IF EXISTS(
    SELECT 1
    FROM jsonb_array_elements(p_lines) input_line
    GROUP BY btrim(COALESCE(input_line->>'lineKey',''))
    HAVING btrim(COALESCE(input_line->>'lineKey',''))=''
       OR count(*)>1
  ) THEN
    RAISE EXCEPTION 'PRICE_PREVIEW_LINE_KEY_INVALID';
  END IF;

  PERFORM set_config(
    'kgs.selected_pricelist_id',
    COALESCE(p_selected_pricelist_id::TEXT,''),
    TRUE
  );

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    BEGIN
      v_line_key:=btrim(v_line->>'lineKey');
      v_product_uom_id:=(v_line->>'productUomId')::UUID;
      v_quantity:=(v_line->>'quantity')::NUMERIC;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'PRICE_PREVIEW_LINE_INVALID';
    END;
    IF v_quantity IS NULL OR v_quantity<=0 THEN
      RAISE EXCEPTION 'SALE_QUANTITY_INVALID';
    END IF;

    v_price:=private.resolve_pos_sale_price(
      v_company,v_session.store_id,p_customer_id,
      v_product_uom_id,v_quantity,v_resolved_at
    );
    SELECT product.sku INTO v_product_sku
    FROM public.products product
    WHERE product.company_id=v_company
      AND product.id=(v_price->>'productId')::UUID;

    v_lines:=v_lines||jsonb_build_array(jsonb_build_object(
      'lineKey',v_line_key,
      'productUomId',v_product_uom_id,
      'productName',v_price->>'productName',
      'productSku',v_product_sku,
      'uomName',v_price->>'uomName',
      'quantity',v_quantity,
      'baseUnitPrice',(v_price->>'baseUnitPrice')::NUMERIC,
      'unitPrice',(v_price->>'resolvedUnitPrice')::NUMERIC,
      'pricelistId',NULLIF(v_price->>'pricelistId','')::UUID,
      'pricelistRuleId',NULLIF(v_price->>'pricelistRuleId','')::UUID,
      'pricelistName',v_price->>'pricelistName',
      'pricingSelectionSource',v_price->>'pricingSelectionSource'
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'companyId',v_company,
    'cashierSessionId',v_session.id,
    'customerId',p_customer_id,
    'selectedPricelistId',p_selected_pricelist_id,
    'resolvedAt',v_resolved_at,
    'lines',v_lines
  );
END
$$;

REVOKE ALL ON FUNCTION public.preview_pos_sale_prices(UUID,UUID,UUID,JSONB)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.preview_pos_sale_prices(UUID,UUID,UUID,JSONB)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20260825100000','pos_live_pricelist_preview',
  'Adds an open-session scoped, read-only POS price preview that reuses the canonical server Pricelist resolver without creating or mutating a Sale Draft'
);

COMMIT;

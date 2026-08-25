-- POS Terminal price override rollback-safe behavior.
-- Requires one active Owner/Admin, Terminal and active sales Product-UOM.

BEGIN;

DO $test$
DECLARE
  v_actor UUID;v_company UUID;v_store UUID;v_terminal UUID;
  v_product_uom UUID;v_version BIGINT;v_old_policy BOOLEAN;
  v_hidden TEXT[];
  v_canonical JSONB;v_overridden JSONB;v_result JSONB;
  v_override NUMERIC(20,4);v_rejected BOOLEAN:=FALSE;
BEGIN
  SELECT membership.user_id,membership.company_id,terminal.store_id,terminal.id,
    terminal.ui_settings_master_version,terminal.allow_price_override,
    terminal.hidden_feature_keys
  INTO v_actor,v_company,v_store,v_terminal,v_version,v_old_policy,v_hidden
  FROM public.company_memberships membership
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  JOIN public.companies company ON company.id=membership.company_id
    AND company.status='ACTIVE'
  JOIN public.pos_terminals terminal ON terminal.company_id=membership.company_id
    AND terminal.status='ACTIVE'
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
  ORDER BY membership.role_code='COMPANY_OWNER' DESC,membership.created_at,
    terminal.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Owner/Admin and Terminal required';
  END IF;

  SELECT product_uom.id INTO v_product_uom
  FROM public.product_uoms product_uom
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active
  JOIN public.uoms uom ON uom.company_id=product_uom.company_id
    AND uom.id=product_uom.uom_id AND uom.is_active
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed AND product_uom.sale_price IS NOT NULL
  ORDER BY product_uom.id LIMIT 1;
  IF v_product_uom IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active sales Product-UOM required';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;

  PERFORM set_config('kgs.pos_price_override_map','{}',TRUE);
  v_canonical:=private.resolve_pos_sale_price(
    v_company,v_store,NULL,v_product_uom,1,clock_timestamp());
  v_override:=round((v_canonical->>'resolvedUnitPrice')::NUMERIC+1234,4);
  PERFORM set_config('kgs.pos_price_override_map',jsonb_build_object(
    v_product_uom::TEXT,v_override)::TEXT,TRUE);
  v_overridden:=private.resolve_pos_sale_price(
    v_company,v_store,NULL,v_product_uom,1,clock_timestamp());
  IF NOT COALESCE((v_overridden->>'priceOverrideApplied')::BOOLEAN,FALSE)
     OR (v_overridden->>'resolvedUnitPrice')::NUMERIC<>v_override
     OR (v_overridden->>'canonicalResolvedUnitPrice')::NUMERIC
        <>(v_canonical->>'resolvedUnitPrice')::NUMERIC THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical versus override resolver invalid';
  END IF;

  PERFORM set_config('kgs.offline_submission_id',gen_random_uuid()::TEXT,TRUE);
  BEGIN
    PERFORM private.resolve_pos_sale_price(
      v_company,v_store,NULL,v_product_uom,1,clock_timestamp());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED' THEN
      v_rejected:=TRUE;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Offline price override was accepted';
  END IF;
  PERFORM set_config('kgs.offline_submission_id','',TRUE);
  PERFORM set_config('kgs.pos_price_override_map','{}',TRUE);

  EXECUTE 'SET LOCAL ROLE authenticated';
  v_result:=public.save_pos_terminal_ui_settings(
    v_terminal,v_version,COALESCE(v_hidden,'{}'::TEXT[]),NOT v_old_policy);
  IF (v_result->>'allowPriceOverride')::BOOLEAN IS DISTINCT FROM NOT v_old_policy
     OR (v_result->>'masterVersion')::BIGINT<>v_version+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Terminal policy update invalid';
  END IF;

  -- Exact retry deliberately uses the original expected version.
  v_result:=public.save_pos_terminal_ui_settings(
    v_terminal,v_version,COALESCE(v_hidden,'{}'::TEXT[]),NOT v_old_policy);
  IF v_result->>'action'<>'EXACT_RETRY'
     OR (v_result->>'masterVersion')::BIGINT<>v_version+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Terminal policy exact retry invalid';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'pos_terminal_price_override_behavior' AS test_name,'PASS' AS status;

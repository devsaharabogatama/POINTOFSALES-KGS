-- Stock Opname partial completion and owner review behavioral test.
-- SAFETY: creates a fixture through canonical public RPC and rolls it back.

BEGIN;

DO $test$
DECLARE
  v_candidate RECORD;v_products UUID[];v_opname_id UUID:=gen_random_uuid();
  v_result JSONB;v_review JSONB;v_version BIGINT;v_denied BOOLEAN:=FALSE;
  v_tested BOOLEAN:=FALSE;
BEGIN
  FOR v_candidate IN
    SELECT session.cashier_id actor_id,session.company_id,
      session.sales_warehouse_id warehouse_id
    FROM public.cashier_sessions session
    JOIN public.company_memberships membership
      ON membership.company_id=session.company_id
     AND membership.user_id=session.cashier_id AND membership.status='ACTIVE'
    WHERE session.status='OPEN'::public.session_status
      AND session.sales_warehouse_id IS NOT NULL
    ORDER BY session.opened_at DESC
  LOOP
    SELECT array_agg(product.id ORDER BY product.id) INTO v_products
    FROM (SELECT product.id FROM public.products product
      JOIN public.product_uoms product_uom
        ON product_uom.company_id=product.company_id
       AND product_uom.product_id=product.id
       AND product_uom.uom_id=product.uom_id
       AND product_uom.factor_to_base=1 AND product_uom.is_active
      JOIN public.uoms uom ON uom.company_id=product.company_id
        AND uom.id=product.uom_id AND uom.is_active
      WHERE product.company_id=v_candidate.company_id
        AND product.is_active AND NOT product.is_bundle
      ORDER BY product.id LIMIT 2) product;
    IF COALESCE(array_length(v_products,1),0)<2 THEN CONTINUE; END IF;
    BEGIN
      PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_candidate.actor_id,'role','authenticated')::TEXT,TRUE);
      PERFORM set_config('request.jwt.claim.sub',v_candidate.actor_id::TEXT,TRUE);
      PERFORM set_config('request.jwt.claim.role','authenticated',TRUE);
      PERFORM public.set_active_company_context(
        v_candidate.company_id,'STOCK_OPNAME_PARTIAL_TEST');
      v_result:=public.get_pos_stock_opname_workspace();
      IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(
        COALESCE(v_result->'warehouses','[]'::JSONB)) warehouse
        WHERE warehouse->>'id'=v_candidate.warehouse_id::TEXT) THEN CONTINUE; END IF;
      v_tested:=TRUE;EXIT;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM IN('CUSTOM_PERMISSION_DENIED','STOCK_OPNAME_COUNTER_REQUIRED')
        THEN CONTINUE;
      END IF;
      RAISE;
    END;
  END LOOP;
  IF NOT v_tested THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: eligible counter with two Products required';
  END IF;

  INSERT INTO public.stock_opnames(id,opname_no,warehouse_id,status,notes,
    created_by,company_id,scope_type,category_id)
  VALUES(v_opname_id,'TEST-PARTIAL-'||replace(v_opname_id::TEXT,'-',''),
    v_candidate.warehouse_id,'DRAFT'::public.opname_status,
    'Rollback partial review fixture',v_candidate.actor_id,
    v_candidate.company_id,'SELECTED',NULL)
  RETURNING master_version INTO v_version;

  v_result:=public.save_stock_opname_session(v_opname_id,v_version,
    v_candidate.warehouse_id,'SELECTED',NULL,to_jsonb(v_products),
    'Rollback partial review test');
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.start_stock_opname(v_opname_id,v_version);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.record_stock_opname_count(v_opname_id,v_version,
    v_products[1],0,'Explicit zero physical count');
  IF v_result->>'lineStatus'<>'COUNTED' THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: concurrent movement requires recount';
  END IF;
  v_version:=(v_result->>'masterVersion')::BIGINT;

  v_review:=public.get_pos_stock_opname_count_review(v_opname_id);
  IF (SELECT count(*) FROM jsonb_array_elements(v_review->'lines') line
      WHERE line->>'productId'=v_products[1]::TEXT
        AND (line->>'enteredQuantity')::NUMERIC=0)<>1
     OR v_review::TEXT ILIKE ANY(ARRAY[
       '%system_qty%','%expected_qty%','%variance%','%difference%']) THEN
    RAISE EXCEPTION 'TEST_FAILED: owner review payload invalid';
  END IF;

  BEGIN
    PERFORM public.complete_stock_opname_partial(
      v_opname_id,v_version,FALSE);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='STOCK_OPNAME_PARTIAL_CONFIRMATION_REQUIRED' THEN
      v_denied:=TRUE;
    ELSE RAISE;
    END IF;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'TEST_FAILED: partial completion lacked explicit confirmation';
  END IF;

  v_result:=public.complete_stock_opname_partial(
    v_opname_id,v_version,TRUE);
  IF v_result->>'status'<>'COMPLETED'
     OR (v_result->>'countedLineCount')::BIGINT<>1
     OR (v_result->>'skippedLineCount')::BIGINT<>1
     OR (SELECT count(*) FROM public.stock_opname_details detail
       WHERE detail.company_id=v_candidate.company_id
         AND detail.opname_id=v_opname_id AND detail.line_status='COUNTED')<>1
     OR (SELECT count(*) FROM public.stock_opname_details detail
       WHERE detail.company_id=v_candidate.company_id
         AND detail.opname_id=v_opname_id AND detail.line_status='SKIPPED'
         AND detail.counted_at IS NULL AND detail.counter_id IS NULL
         AND detail.expected_qty_at_count IS NULL
         AND detail.variance_at_count IS NULL)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: partial completion state invalid';
  END IF;

  v_result:=public.complete_stock_opname_partial(
    v_opname_id,v_version,TRUE);
  IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
     OR (v_result->>'masterVersion')::BIGINT<>v_version+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: partial completion exact retry invalid';
  END IF;

  RAISE NOTICE 'TEST PASSED: own zero count is reviewable, partial completion requires confirmation, exact retry is stable, and unresolved line becomes SKIPPED; all writes roll back.';
END
$test$;

ROLLBACK;

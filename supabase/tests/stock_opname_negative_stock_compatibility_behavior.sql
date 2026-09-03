-- Stock Opname negative-stock compatibility behavioral test.
-- SAFETY: uses current eligible negative-stock data and rolls every write back.

BEGIN;

DO $test$
DECLARE
  v_candidate RECORD;
  v_result JSONB;
  v_opname_id UUID;
  v_version BIGINT;
  v_line RECORD;
  v_tested BOOLEAN:=FALSE;
BEGIN
  FOR v_candidate IN
    SELECT session.cashier_id actor_id,session.company_id,
      session.sales_warehouse_id warehouse_id,stock.product_id,stock.stock_qty
    FROM public.cashier_sessions session
    JOIN public.company_memberships membership
      ON membership.company_id=session.company_id
     AND membership.user_id=session.cashier_id
     AND membership.status='ACTIVE'
    JOIN public.product_stocks stock
      ON stock.company_id=session.company_id
     AND stock.warehouse_id=session.sales_warehouse_id
     AND stock.stock_qty<0
    JOIN public.products product
      ON product.company_id=stock.company_id AND product.id=stock.product_id
     AND product.is_active AND NOT product.is_bundle
    JOIN public.product_uoms product_uom
      ON product_uom.company_id=product.company_id
     AND product_uom.product_id=product.id AND product_uom.uom_id=product.uom_id
     AND product_uom.factor_to_base=1 AND product_uom.is_active
    JOIN public.uoms uom ON uom.company_id=product.company_id
      AND uom.id=product.uom_id AND uom.is_active
    WHERE session.status='OPEN'::public.session_status
      AND session.sales_warehouse_id IS NOT NULL
    ORDER BY stock.stock_qty,session.opened_at DESC
  LOOP
    BEGIN
      PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_candidate.actor_id,'role','authenticated')::TEXT,TRUE);
      PERFORM set_config('request.jwt.claim.sub',v_candidate.actor_id::TEXT,TRUE);
      PERFORM set_config('request.jwt.claim.role','authenticated',TRUE);
      PERFORM public.set_active_company_context(
        v_candidate.company_id,'STOCK_OPNAME_NEGATIVE_TEST');
      v_result:=public.get_pos_stock_opname_workspace();
      IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(
        COALESCE(v_result->'warehouses','[]'::JSONB)) warehouse
        WHERE warehouse->>'id'=v_candidate.warehouse_id::TEXT) THEN
        CONTINUE;
      END IF;
      v_tested:=TRUE;
      EXIT;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM IN('CUSTOM_PERMISSION_DENIED','STOCK_OPNAME_COUNTER_REQUIRED')
         THEN CONTINUE;
      END IF;
      RAISE;
    END;
  END LOOP;

  IF NOT v_tested THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: eligible open-session negative-stock counter required';
  END IF;

  v_opname_id:=gen_random_uuid();
  INSERT INTO public.stock_opnames(
    id,opname_no,warehouse_id,status,notes,created_by,company_id,
    scope_type,category_id
  ) VALUES(
    v_opname_id,'TEST-NEG-'||replace(v_opname_id::TEXT,'-',''),
    v_candidate.warehouse_id,'DRAFT'::public.opname_status,
    'Rollback negative-stock compatibility fixture',v_candidate.actor_id,
    v_candidate.company_id,'SELECTED',NULL
  ) RETURNING master_version INTO v_version;

  v_result:=public.save_stock_opname_session(
    v_opname_id,v_version,v_candidate.warehouse_id,'SELECTED',NULL,
    jsonb_build_array(v_candidate.product_id),
    'Rollback negative-stock compatibility test');
  v_version:=(v_result->>'masterVersion')::BIGINT;

  SELECT system_qty,system_qty_at_start,physical_qty
  INTO v_line FROM public.stock_opname_details
  WHERE company_id=v_candidate.company_id AND opname_id=v_opname_id
    AND product_id=v_candidate.product_id;
  IF v_line.system_qty IS DISTINCT FROM v_candidate.stock_qty
     OR v_line.system_qty_at_start IS DISTINCT FROM v_candidate.stock_qty
     OR v_line.system_qty>=0 OR v_line.physical_qty<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: signed Draft snapshot invalid';
  END IF;

  v_result:=public.start_stock_opname(v_opname_id,v_version);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.record_stock_opname_count(
    v_opname_id,v_version,v_candidate.product_id,0,
    'Rollback physical zero count');

  SELECT expected_qty_at_count,physical_qty,variance_at_count,difference
  INTO v_line FROM public.stock_opname_details
  WHERE company_id=v_candidate.company_id AND opname_id=v_opname_id
    AND product_id=v_candidate.product_id;
  IF v_line.physical_qty<>0 OR v_line.expected_qty_at_count IS NULL
     OR v_line.variance_at_count IS DISTINCT FROM
       v_line.physical_qty-v_line.expected_qty_at_count
     OR v_line.difference IS DISTINCT FROM v_line.variance_at_count THEN
    RAISE EXCEPTION 'TEST_FAILED: signed count variance invalid';
  END IF;

  RAISE NOTICE 'TEST PASSED: negative system Stock Opname Draft and zero physical blind count work through canonical public RPC; all writes roll back.';
END
$test$;

ROLLBACK;

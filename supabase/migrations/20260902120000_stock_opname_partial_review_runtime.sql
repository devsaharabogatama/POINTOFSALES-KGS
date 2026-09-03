-- Operational Stock Opname partial completion and owner count review.
-- PENDING/RECOUNT_REQUIRED lines may be explicitly skipped at completion;
-- only COUNTED lines remain eligible for Adjustment posting.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260902110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: negative Stock Opname compatibility required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260902120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF to_regprocedure('private.post_stock_opname(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('private.acp_require_stock_opname_counter(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Stock Opname runtime missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_opname_details
    WHERE line_status NOT IN(
      'PENDING','COUNTED','RECOUNT_REQUIRED','SUPERSEDED','POSTED'
    )) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected Stock Opname line status';
  END IF;
END
$guard$;

ALTER TABLE public.stock_opname_details
  DROP CONSTRAINT stock_opname_details_line_status_check,
  DROP CONSTRAINT stock_opname_details_count_shape;

ALTER TABLE public.stock_opname_details
  ADD CONSTRAINT stock_opname_details_line_status_check CHECK(
    line_status IN(
      'PENDING','COUNTED','RECOUNT_REQUIRED','SKIPPED','SUPERSEDED','POSTED'
    )
  ),
  ADD CONSTRAINT stock_opname_details_count_shape CHECK(
    (
      line_status IN('PENDING','SKIPPED')
      AND counted_at IS NULL
      AND counter_id IS NULL
      AND expected_qty_at_count IS NULL
      AND variance_at_count IS NULL
    ) OR (
      line_status IN('COUNTED','RECOUNT_REQUIRED','POSTED')
      AND counted_at IS NOT NULL
      AND counter_id IS NOT NULL
      AND expected_qty_at_count IS NOT NULL
      AND variance_at_count IS NOT NULL
    ) OR line_status='SUPERSEDED'
  );

COMMENT ON CONSTRAINT stock_opname_details_count_shape
ON public.stock_opname_details IS
  'SKIPPED is an explicit no-result state; zero stock must be recorded as COUNTED physical quantity 0.';

CREATE FUNCTION private.complete_stock_opname_partial(
  p_opname_id UUID,p_master_version BIGINT,p_skip_unresolved BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_opname public.stock_opnames%ROWTYPE;
  v_now TIMESTAMPTZ:=clock_timestamp();
  v_counted BIGINT;v_unresolved BIGINT;v_skipped BIGINT:=0;v_version BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_opname FROM public.stock_opnames opname
  WHERE opname.company_id=v_company AND opname.id=p_opname_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  IF v_opname.created_by<>v_actor
     OR NOT public.private_stock_opname_counter_allowed(
       v_company,v_opname.warehouse_id) THEN
    RAISE EXCEPTION 'STOCK_OPNAME_OWNER_COUNTER_REQUIRED';
  END IF;
  IF v_opname.status='COMPLETED'::public.opname_status
     AND v_opname.completed_by=v_actor
     AND v_opname.master_version=p_master_version+1 THEN
    SELECT count(*) FILTER(WHERE detail.line_status='COUNTED'),
      count(*) FILTER(WHERE detail.line_status='SKIPPED')
    INTO v_counted,v_skipped
    FROM public.stock_opname_details detail
    WHERE detail.company_id=v_company AND detail.opname_id=v_opname.id;
    RETURN jsonb_build_object('opnameId',v_opname.id,'status','COMPLETED',
      'masterVersion',v_opname.master_version,'countedLineCount',v_counted,
      'skippedLineCount',v_skipped,'partialCompletion',v_skipped>0,
      'idempotentReplay',TRUE);
  END IF;
  IF v_opname.status<>'COUNTING'::public.opname_status THEN
    RAISE EXCEPTION 'STOCK_OPNAME_COUNTING_REQUIRED';
  END IF;
  IF p_master_version IS DISTINCT FROM v_opname.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;

  SELECT count(*) FILTER(WHERE detail.line_status='COUNTED'),
    count(*) FILTER(WHERE detail.line_status IN('PENDING','RECOUNT_REQUIRED'))
  INTO v_counted,v_unresolved
  FROM public.stock_opname_details detail
  WHERE detail.company_id=v_company AND detail.opname_id=v_opname.id;

  IF v_counted=0 THEN RAISE EXCEPTION 'STOCK_OPNAME_NO_ACTIVE_COUNTED_LINE'; END IF;
  IF v_unresolved>0 AND NOT COALESCE(p_skip_unresolved,FALSE) THEN
    RAISE EXCEPTION 'STOCK_OPNAME_PARTIAL_CONFIRMATION_REQUIRED';
  END IF;

  IF v_unresolved>0 THEN
    UPDATE public.stock_opname_details SET
      line_status='SKIPPED',physical_qty=0,difference=0,
      expected_qty_at_count=NULL,variance_at_count=NULL,
      counted_at=NULL,counter_id=NULL
    WHERE company_id=v_company AND opname_id=v_opname.id
      AND line_status IN('PENDING','RECOUNT_REQUIRED');
    GET DIAGNOSTICS v_skipped=ROW_COUNT;
  END IF;

  UPDATE public.stock_opnames SET
    status='COMPLETED'::public.opname_status,
    completed_by=v_actor,completed_at=v_now,updated_at=v_now,
    master_version=master_version+1
  WHERE company_id=v_company AND id=v_opname.id
  RETURNING master_version INTO v_version;

  INSERT INTO public.stock_opname_audit(
    company_id,opname_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,v_opname.id,'COMPLETE',v_actor,to_jsonb(v_opname),
    jsonb_build_object('status','COMPLETED','completedAt',v_now,
      'countedLineCount',v_counted,'skippedLineCount',v_skipped,
      'partialCompletion',v_skipped>0));

  RETURN jsonb_build_object('opnameId',v_opname.id,'status','COMPLETED',
    'masterVersion',v_version,'countedLineCount',v_counted,
    'skippedLineCount',v_skipped,'partialCompletion',v_skipped>0,
    'idempotentReplay',FALSE);
END
$$;

CREATE FUNCTION public.complete_stock_opname_partial(
  p_opname_id UUID,p_master_version BIGINT,p_skip_unresolved BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_warehouse UUID;
BEGIN
  SELECT warehouse_id INTO v_warehouse FROM public.stock_opnames
  WHERE company_id=v_company AND id=p_opname_id;
  IF v_warehouse IS NULL THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  PERFORM private.acp_require_stock_opname_counter(
    v_company,v_warehouse,'EDIT_DRAFT');
  RETURN private.complete_stock_opname_partial(
    p_opname_id,p_master_version,p_skip_unresolved);
END
$$;

CREATE FUNCTION public.get_pos_stock_opname_count_review(p_opname_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_opname public.stock_opnames%ROWTYPE;v_lines JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_opname FROM public.stock_opnames opname
  WHERE opname.company_id=v_company AND opname.id=p_opname_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  IF v_opname.created_by<>v_actor THEN
    RAISE EXCEPTION 'STOCK_OPNAME_OWNER_COUNTER_REQUIRED';
  END IF;
  PERFORM private.acp_require_stock_opname_counter(
    v_company,v_opname.warehouse_id,'EDIT_DRAFT');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'detailId',detail.id,'productId',detail.product_id,
    'sku',detail.product_sku_snapshot,
    'productName',detail.product_name_snapshot,
    'uomName',detail.base_uom_name_snapshot,
    'lineStatus',detail.line_status,'notes',detail.notes,
    'enteredQuantity',CASE WHEN detail.line_status IN('COUNTED','POSTED')
      THEN detail.physical_qty ELSE NULL END,
    'canEdit',v_opname.status='COUNTING'::public.opname_status
      AND detail.line_status IN('PENDING','COUNTED')
  ) ORDER BY detail.product_name_snapshot,detail.id),'[]'::JSONB)
  INTO v_lines FROM public.stock_opname_details detail
  WHERE detail.company_id=v_company AND detail.opname_id=v_opname.id
    AND detail.line_status<>'SUPERSEDED';

  RETURN jsonb_build_object('opnameId',v_opname.id,
    'opnameNo',v_opname.opname_no,'warehouseId',v_opname.warehouse_id,
    'status',v_opname.status,'masterVersion',v_opname.master_version,
    'lines',v_lines);
END
$$;

-- Preserve the trusted Adjustment core and broaden only the terminal line
-- validation to accept explicit SKIPPED lines. Posting still builds adjustment
-- input exclusively from COUNTED lines.
CREATE OR REPLACE FUNCTION private.post_stock_opname(
  p_opname_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_opname public.stock_opnames%ROWTYPE;v_reason_id UUID;v_lines JSONB;
  v_adjustment JSONB;v_adjustment_id UUID;v_adjustment_version BIGINT;
  v_now TIMESTAMPTZ:=clock_timestamp();v_version BIGINT;v_nonzero INTEGER;
BEGIN
  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'STOCK_OPNAME_IDEMPOTENCY_KEY_REQUIRED';
  END IF;
  SELECT * INTO v_opname FROM public.stock_opnames opname
  WHERE opname.company_id=v_company AND opname.id=p_opname_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  IF v_opname.status='POSTED'::public.opname_status THEN
    IF v_opname.posting_idempotency_key=p_idempotency_key THEN
      RETURN jsonb_build_object('opnameId',v_opname.id,
        'opnameNo',v_opname.opname_no,'status','POSTED',
        'masterVersion',v_opname.master_version,
        'adjustmentDocumentId',v_opname.adjustment_document_id,
        'idempotentReplay',TRUE);
    END IF;
    RAISE EXCEPTION 'STOCK_OPNAME_IDEMPOTENCY_CONFLICT';
  END IF;
  IF NOT public.private_stock_adjustment_operator_allowed(
    v_company,v_opname.warehouse_id) THEN
    RAISE EXCEPTION 'STOCK_OPNAME_REVIEWER_REQUIRED';
  END IF;
  IF v_opname.status<>'COMPLETED'::public.opname_status THEN
    RAISE EXCEPTION 'STOCK_OPNAME_COMPLETED_REQUIRED';
  END IF;
  IF p_master_version IS DISTINCT FROM v_opname.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_opname_details detail
    WHERE detail.company_id=v_company AND detail.opname_id=v_opname.id
      AND detail.line_status NOT IN('COUNTED','SKIPPED','SUPERSEDED')) THEN
    RAISE EXCEPTION 'STOCK_OPNAME_UNRESOLVED_LINE';
  END IF;

  SELECT id INTO v_reason_id FROM public.stock_adjustment_reasons
  WHERE company_id=v_company AND is_active AND direction_allowed='BOTH'
    AND lower(regexp_replace(btrim(reason_name),'\s+',' ','g'))='selisih stok'
  ORDER BY is_system_default DESC,id LIMIT 1;
  IF v_reason_id IS NULL THEN
    RAISE EXCEPTION 'STOCK_OPNAME_ADJUSTMENT_REASON_NOT_FOUND';
  END IF;

  SELECT count(*),jsonb_agg(jsonb_build_object(
    'productId',detail.product_id,'reasonId',v_reason_id,
    'finalPhysicalQuantity',COALESCE(stock.stock_qty,0)+detail.variance_at_count,
    'notes','Generated from Stock Opname '||v_opname.opname_no)
    ORDER BY detail.product_id)
  INTO v_nonzero,v_lines
  FROM public.stock_opname_details detail
  LEFT JOIN public.product_stocks stock
    ON stock.company_id=detail.company_id AND stock.product_id=detail.product_id
   AND stock.warehouse_id=v_opname.warehouse_id
  WHERE detail.company_id=v_company AND detail.opname_id=v_opname.id
    AND detail.line_status='COUNTED' AND detail.variance_at_count<>0;

  IF EXISTS(SELECT 1 FROM public.stock_opname_details detail
    LEFT JOIN public.product_stocks stock
      ON stock.company_id=detail.company_id AND stock.product_id=detail.product_id
     AND stock.warehouse_id=v_opname.warehouse_id
    WHERE detail.company_id=v_company AND detail.opname_id=v_opname.id
      AND detail.line_status='COUNTED'
      AND COALESCE(stock.stock_qty,0)+detail.variance_at_count<0) THEN
    RAISE EXCEPTION 'STOCK_OPNAME_FINAL_STOCK_NEGATIVE';
  END IF;

  IF v_nonzero>0 THEN
    v_adjustment:=private.save_stock_adjustment_document(NULL,NULL,
      v_opname.warehouse_id,CURRENT_DATE,
      'Generated from Stock Opname '||v_opname.opname_no,v_lines);
    v_adjustment_id:=(v_adjustment->>'documentId')::UUID;
    v_adjustment_version:=(v_adjustment->>'masterVersion')::BIGINT;
    UPDATE public.stock_adjustment_lines adjustment SET opname_detail_id=detail.id
    FROM public.stock_opname_details detail
    WHERE adjustment.company_id=v_company
      AND adjustment.document_id=v_adjustment_id
      AND detail.company_id=adjustment.company_id
      AND detail.opname_id=v_opname.id
      AND detail.product_id=adjustment.product_id;
    PERFORM private.post_stock_adjustment(
      v_adjustment_id,v_adjustment_version,p_idempotency_key);
    UPDATE public.stock_opname_details detail SET
      line_status=CASE WHEN detail.line_status='COUNTED'
        THEN 'POSTED' ELSE detail.line_status END,
      adjustment_line_id=adjustment.id
    FROM public.stock_adjustment_lines adjustment
    WHERE detail.company_id=v_company AND detail.opname_id=v_opname.id
      AND adjustment.company_id=detail.company_id
      AND adjustment.document_id=v_adjustment_id
      AND adjustment.product_id=detail.product_id;
  END IF;
  UPDATE public.stock_opname_details SET line_status='POSTED'
  WHERE company_id=v_company AND opname_id=v_opname.id
    AND line_status='COUNTED';
  UPDATE public.stock_opnames SET status='POSTED'::public.opname_status,
    adjustment_document_id=v_adjustment_id,
    posting_idempotency_key=p_idempotency_key,
    reviewed_by=COALESCE(reviewed_by,v_actor),
    reviewed_at=COALESCE(reviewed_at,v_now),posted_by=v_actor,
    posted_at=v_now,updated_at=v_now,master_version=master_version+1
  WHERE company_id=v_company AND id=v_opname.id
  RETURNING master_version INTO v_version;
  INSERT INTO public.stock_opname_audit(
    company_id,opname_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,v_opname.id,'POST',v_actor,to_jsonb(v_opname),
    jsonb_build_object('status','POSTED','postedAt',v_now,
      'adjustmentDocumentId',v_adjustment_id));
  RETURN jsonb_build_object('opnameId',v_opname.id,
    'opnameNo',v_opname.opname_no,'status','POSTED',
    'masterVersion',v_version,'adjustmentDocumentId',v_adjustment_id,
    'idempotentReplay',FALSE);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'STOCK_OPNAME_IDEMPOTENCY_CONFLICT';
END
$$;

-- Extend the existing workspace response with an explicit skipped counter.
CREATE OR REPLACE FUNCTION public.get_pos_stock_opname_workspace()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor UUID:=auth.uid();
  v_company UUID:=public.private_active_company_id();
  v_resolution JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  v_resolution:=private.acp_resolve_permission(
    v_company,v_actor,'inventory.stock_opnames');
  IF (v_resolution->>'enforced')::BOOLEAN
     AND v_resolution->>'restrictionPreset' IN('LIHAT_SAJA','TANPA_AKSES') THEN
    RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.is_active
      AND public.private_stock_opname_counter_allowed(
        v_company,warehouse.id)) THEN
    RAISE EXCEPTION 'STOCK_OPNAME_COUNTER_REQUIRED';
  END IF;

  RETURN jsonb_build_object('companyId',v_company,
    'warehouses',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'name',warehouse.name,'storeId',warehouse.store_id)
      ORDER BY warehouse.name,warehouse.id)
      FROM public.warehouses warehouse
      WHERE warehouse.company_id=v_company AND warehouse.is_active
        AND public.private_stock_opname_counter_allowed(
          v_company,warehouse.id)),'[]'::JSONB),
    'categories',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',category.id,'name',category.category_name)
      ORDER BY category.category_name,category.id)
      FROM public.product_categories category
      WHERE category.company_id=v_company AND category.is_active
        AND EXISTS(SELECT 1 FROM public.products product
          JOIN public.product_uoms product_uom
            ON product_uom.company_id=product.company_id
           AND product_uom.product_id=product.id
           AND product_uom.uom_id=product.uom_id
           AND product_uom.factor_to_base=1 AND product_uom.is_active
          WHERE product.company_id=v_company
            AND product.category_id=category.id
            AND product.is_active AND NOT product.is_bundle)),
      '[]'::JSONB),
    'products',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',product.id,'sku',product.sku,'name',product.name,
      'categoryId',product.category_id,'uomName',uom.name,
      'allowDecimal',uom.allow_decimal,
      'decimalPrecision',uom.decimal_precision)
      ORDER BY product.name,product.sku,product.id)
      FROM public.products product
      JOIN public.product_uoms product_uom
        ON product_uom.company_id=product.company_id
       AND product_uom.product_id=product.id
       AND product_uom.uom_id=product.uom_id
       AND product_uom.factor_to_base=1 AND product_uom.is_active
      JOIN public.uoms uom ON uom.company_id=product.company_id
        AND uom.id=product.uom_id AND uom.is_active
      WHERE product.company_id=v_company AND product.is_active
        AND NOT product.is_bundle),'[]'::JSONB),
    'sessions',COALESCE((SELECT jsonb_agg(to_jsonb(session_row)
      ORDER BY session_row.created_at DESC,session_row.id)
      FROM (SELECT opname.id,opname.opname_no,opname.warehouse_id,
        warehouse.name warehouse_name,opname.status,opname.scope_type,
        opname.category_id,opname.notes,opname.master_version,
        opname.created_at,opname.updated_at,
        count(*) FILTER(WHERE line.line_status<>'SUPERSEDED') line_count,
        count(*) FILTER(WHERE line.line_status='PENDING') pending_count,
        count(*) FILTER(WHERE line.line_status='COUNTED') counted_count,
        count(*) FILTER(WHERE line.line_status='RECOUNT_REQUIRED')
          recount_required_count,
        count(*) FILTER(WHERE line.line_status='SKIPPED') skipped_count
      FROM public.stock_opnames opname
      JOIN public.warehouses warehouse
        ON warehouse.company_id=opname.company_id
       AND warehouse.id=opname.warehouse_id
      LEFT JOIN public.stock_opname_details line
        ON line.company_id=opname.company_id AND line.opname_id=opname.id
      WHERE opname.company_id=v_company AND opname.created_by=v_actor
        AND public.private_stock_opname_counter_allowed(
          v_company,opname.warehouse_id)
      GROUP BY opname.id,opname.opname_no,opname.warehouse_id,
        warehouse.name,opname.status,opname.scope_type,opname.category_id,
        opname.notes,opname.master_version,opname.created_at,opname.updated_at
      ORDER BY opname.created_at DESC,opname.id LIMIT 100) session_row),
      '[]'::JSONB));
END
$$;

REVOKE ALL ON FUNCTION
  private.complete_stock_opname_partial(UUID,BIGINT,BOOLEAN)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.complete_stock_opname_partial(UUID,BIGINT,BOOLEAN)
TO service_role;

REVOKE ALL ON FUNCTION
  public.complete_stock_opname_partial(UUID,BIGINT,BOOLEAN),
  public.get_pos_stock_opname_count_review(UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.complete_stock_opname_partial(UUID,BIGINT,BOOLEAN),
  public.get_pos_stock_opname_count_review(UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260902120000','stock_opname_partial_review_runtime',
  'Added explicit SKIPPED partial completion and owner-only count review without exposing system quantity or changing counted-only Adjustment posting');

NOTIFY pgrst,'reload schema';
COMMIT;

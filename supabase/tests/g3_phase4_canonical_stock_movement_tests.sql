-- G3 phase 4 behavioral test: Opening enrichment and immutable movement.
-- SAFETY: fixture document, line, and movement are rolled back.

BEGIN;

DO $test$
DECLARE
    v_source public.stock_movements%ROWTYPE;
    v_source_line public.opening_stock_lines%ROWTYPE;
    v_actor UUID;
    v_document UUID := '00000000-0000-0000-0000-000000049001';
    v_line UUID := '00000000-0000-0000-0000-000000049002';
    v_movement UUID;
    v_current_balance NUMERIC;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT sm.* INTO v_source
    FROM public.stock_movements sm
    WHERE sm.movement_type =
        'OPENING_BALANCE'::public.stock_movement_type
    ORDER BY sm.created_at,sm.id
    LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: existing Opening movement required';
    END IF;

    SELECT l.* INTO v_source_line
    FROM public.opening_stock_lines l
    WHERE l.company_id = v_source.company_id
      AND l.id = v_source.source_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: canonical Opening line required';
    END IF;

    v_actor := v_source.actor_id;
    SELECT stock_qty INTO v_current_balance
    FROM public.product_stocks
    WHERE company_id = v_source.company_id
      AND product_id = v_source.product_id
      AND warehouse_id = v_source.warehouse_id;

    INSERT INTO public.opening_stock_documents(
        id,company_id,document_no,warehouse_id,effective_date,status,
        notes,line_count,total_quantity_base,total_cost,
        created_by,updated_by
    ) VALUES (
        v_document,v_source.company_id,
        'G3-PHASE4-ROLLBACK-' || replace(v_document::TEXT,'-',''),
        v_source.warehouse_id,current_date,'DRAFT',
        'Rollback-only canonical movement test',1,1,
        v_source_line.unit_cost_base,v_actor,v_actor
    );

    INSERT INTO public.opening_stock_lines(
        id,company_id,document_id,line_no,product_id,base_uom_id,
        quantity_base,unit_cost_base,total_cost,
        product_sku_snapshot,product_name_snapshot,
        base_uom_code_snapshot,base_uom_name_snapshot,
        zero_cost_reason,notes
    ) VALUES (
        v_line,v_source.company_id,v_document,1,v_source.product_id,
        v_source_line.base_uom_id,1,v_source_line.unit_cost_base,
        round(v_source_line.unit_cost_base,4),
        v_source_line.product_sku_snapshot,
        v_source_line.product_name_snapshot,
        v_source_line.base_uom_code_snapshot,
        v_source_line.base_uom_name_snapshot,
        v_source_line.zero_cost_reason,
        'Canonical trigger test'
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );

    INSERT INTO public.stock_movements(
        company_id,product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id
    ) VALUES (
        v_source.company_id,v_source.product_id,v_source.warehouse_id,1,
        'OPENING_BALANCE'::public.stock_movement_type,
        'opening_stock_documents',v_document
    )
    RETURNING id INTO v_movement;

    SELECT count(*) INTO v_count
    FROM public.stock_movements sm
    WHERE sm.id = v_movement
      AND sm.base_uom_id = v_source_line.base_uom_id
      AND sm.base_uom_name_snapshot =
          v_source_line.base_uom_name_snapshot
      AND sm.balance_after_base_qty = v_current_balance + 1
      AND sm.actor_id = v_actor
      AND sm.posted_at IS NOT NULL
      AND sm.movement_status = 'POSTED'
      AND sm.source_line_id = v_line
      AND sm.notes = 'Canonical trigger test';
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Opening movement enrichment invalid';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.stock_movements
        SET notes = 'Forbidden edit'
        WHERE id = v_movement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'STOCK_MOVEMENT_IMMUTABLE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: movement update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        DELETE FROM public.stock_movements WHERE id = v_movement;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'STOCK_MOVEMENT_IMMUTABLE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: movement delete accepted';
    END IF;

    IF has_table_privilege(
        'authenticated','public.stock_movements','INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: authenticated movement write remains';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Opening movement is canonical, source-identified, balance-snapshotted, and immutable.';
END
$test$;

ROLLBACK;

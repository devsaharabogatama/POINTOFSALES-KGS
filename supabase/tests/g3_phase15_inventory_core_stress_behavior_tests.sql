-- G3 phase 15 integrated inventory-core stress behavior.
--
-- SAFETY:
-- - every Company/master/stock/FIFO/document/audit/event fixture is rolled back;
-- - no checkout, Sale, Return, Receipt, journal posting, or persistent change.
--
-- NOTE:
-- - twenty competing Transfer posts are serialized in this SQL transaction;
-- - this proves atomic rejection, idempotency, and reconciliation under repeated
--   contention, but does not claim true multi-session concurrency coverage.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_bundle_id UUID;
    v_transfer_id UUID;
    v_adjustment_id UUID;
    v_reason_id UUID;
    v_result JSONB;
    v_competing_id UUID;
    v_success INTEGER := 0;
    v_rejected_count INTEGER := 0;
    v_count BIGINT;
    v_qty NUMERIC;
    v_i INTEGER;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES (
        '00000000-0000-0000-0000-000000055001',
        'G55A','G55 Stress Company','g55-stress-company','ACTIVE'
    );
    INSERT INTO public.product_categories(
        id,company_id,category_code,category_name
    ) VALUES (
        '00000000-0000-0000-0000-000000055011',
        '00000000-0000-0000-0000-000000055001',
        'G55-CAT','G55 Stress Category'
    );
    INSERT INTO public.uoms(id,company_id,code,name) VALUES
        (
            '00000000-0000-0000-0000-000000055021',
            '00000000-0000-0000-0000-000000055001',
            'G55-PCS','G55 Piece'
        ),
        (
            '00000000-0000-0000-0000-000000055022',
            '00000000-0000-0000-0000-000000055001',
            'G55-PAK','G55 Paket'
        );
    INSERT INTO public.products(
        id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
        weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
    ) VALUES (
        '00000000-0000-0000-0000-000000055031',
        '00000000-0000-0000-0000-000000055001',
        'G55-P','G55 Component','G55 Stress Category',
        '00000000-0000-0000-0000-000000055011',
        100,50,'G55-PCS',
        '00000000-0000-0000-0000-000000055021',
        '00000000-0000-0000-0000-000000055021',
        1,TRUE,FALSE
    );
    INSERT INTO public.product_uoms(
        company_id,product_id,uom_id,factor_to_base,
        purchase_allowed,sales_allowed,purchase_price,sale_price
    ) VALUES (
        '00000000-0000-0000-0000-000000055001',
        '00000000-0000-0000-0000-000000055031',
        '00000000-0000-0000-0000-000000055021',
        1,TRUE,TRUE,50,100
    );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,is_active,is_sale_source
    ) VALUES
        (
            '00000000-0000-0000-0000-000000055041',
            '00000000-0000-0000-0000-000000055001',
            'G55-S','G55 Source','CENTRAL',TRUE,TRUE
        ),
        (
            '00000000-0000-0000-0000-000000055042',
            '00000000-0000-0000-0000-000000055001',
            'G55-D','G55 Destination','CENTRAL',TRUE,TRUE
        );

    -- Two positive FIFO layers are fixture-only. The canonical Transfer and
    -- Adjustment paths under test own every mutation after this baseline.
    INSERT INTO public.product_stocks(
        company_id,product_id,warehouse_id,stock_qty
    ) VALUES (
        '00000000-0000-0000-0000-000000055001',
        '00000000-0000-0000-0000-000000055031',
        '00000000-0000-0000-0000-000000055041',10
    );
    INSERT INTO public.product_batches(
        id,company_id,product_id,warehouse_id,
        qty_purchased,qty_remaining,cogs_unit
    ) VALUES
        (
            '00000000-0000-0000-0000-000000055051',
            '00000000-0000-0000-0000-000000055001',
            '00000000-0000-0000-0000-000000055031',
            '00000000-0000-0000-0000-000000055041',
            6,6,5
        ),
        (
            '00000000-0000-0000-0000-000000055052',
            '00000000-0000-0000-0000-000000055001',
            '00000000-0000-0000-0000-000000055031',
            '00000000-0000-0000-0000-000000055041',
            4,4,7
        );
    INSERT INTO public.stock_movements(
        product_id,warehouse_id,qty_change,movement_type,
        reference_table,reference_id,company_id,
        base_uom_id,base_uom_name_snapshot,balance_after_base_qty,
        actor_id,posted_at,movement_status,source_line_id,notes
    ) VALUES (
        '00000000-0000-0000-0000-000000055031',
        '00000000-0000-0000-0000-000000055041',
        10,'PURCHASE'::public.stock_movement_type,
        'G3_PHASE15_FIXTURE',
        '00000000-0000-0000-0000-000000055061',
        '00000000-0000-0000-0000-000000055001',
        '00000000-0000-0000-0000-000000055021',
        'G55 Piece',10,v_actor,clock_timestamp(),'POSTED',
        '00000000-0000-0000-0000-000000055062',
        'Rollback-only two-layer baseline'
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000055001',
        'G3_PHASE15_STRESS_TEST'
    );

    v_result := public.save_bundle_with_components(
        NULL,NULL,'G55-B','G55 Bundle',
        '00000000-0000-0000-0000-000000055011',
        '00000000-0000-0000-0000-000000055022',
        180,NULL,NULL,TRUE,
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000055031',
            'uomId','00000000-0000-0000-0000-000000055021',
            'quantity',2
        ))
    );
    v_bundle_id := (v_result->>'bundleId')::UUID;
    IF (
        public.get_bundle_availability(
            v_bundle_id,
            '00000000-0000-0000-0000-000000055041'
        )->>'availableQuantity'
    )::BIGINT <> 5 THEN
        RAISE EXCEPTION
            'TEST_FAILED: initial Bundle availability must be 5';
    END IF;

    -- One multi-layer Transfer consumes six units at cost 5 and two at cost 7.
    v_result := public.save_stock_transfer_document(
        NULL,NULL,
        '00000000-0000-0000-0000-000000055041',
        '00000000-0000-0000-0000-000000055042',
        CURRENT_DATE,'G55 multi-layer transfer',
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000055031',
            'quantityBase',8
        ))
    );
    v_transfer_id := (v_result->>'documentId')::UUID;
    v_result := public.post_stock_transfer(
        v_transfer_id,1,
        '00000000-0000-0000-0000-000000055071'
    );
    IF (v_result->>'totalCost')::NUMERIC <> 44 THEN
        RAISE EXCEPTION
            'TEST_FAILED: multi-layer FIFO cost must be 44';
    END IF;
    v_result := public.post_stock_transfer(
        v_transfer_id,2,
        '00000000-0000-0000-0000-000000055071'
    );
    IF NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
        RAISE EXCEPTION
            'TEST_FAILED: Transfer retry was not idempotent';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.stock_movements
    WHERE reference_table = 'stock_transfer_documents'
      AND reference_id = v_transfer_id;
    IF v_count <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Transfer retry duplicated Movement';
    END IF;

    -- Adjustment gain creates another FIFO layer through the guarded path.
    SELECT id INTO v_reason_id
    FROM public.stock_adjustment_reasons
    WHERE company_id = '00000000-0000-0000-0000-000000055001'
      AND reason_name = 'Selisih Stok';
    IF v_reason_id IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: default Adjustment reason missing';
    END IF;
    v_result := public.save_stock_adjustment_document(
        NULL,NULL,
        '00000000-0000-0000-0000-000000055041',
        CURRENT_DATE,'G55 replenish for contention',
        jsonb_build_array(jsonb_build_object(
            'productId','00000000-0000-0000-0000-000000055031',
            'reasonId',v_reason_id,
            'finalPhysicalQuantity',5,
            'unitCostBase',9,
            'costOverrideReason','Rollback-only stress fixture'
        ))
    );
    v_adjustment_id := (v_result->>'documentId')::UUID;
    v_result := public.post_stock_adjustment(
        v_adjustment_id,1,
        '00000000-0000-0000-0000-000000055072'
    );
    IF (v_result->>'totalGainValue')::NUMERIC <> 27 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Adjustment gain value must be 27';
    END IF;
    IF (
        public.get_bundle_availability(
            v_bundle_id,
            '00000000-0000-0000-0000-000000055041'
        )->>'availableQuantity'
    )::BIGINT <> 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: replenished Bundle availability must be 2';
    END IF;

    -- Twenty competing Drafts ask for one unit each. Only the five backed by
    -- current balance/FIFO may post; every loser must remain cleanly DRAFT.
    FOR v_i IN 1..20 LOOP
        v_result := public.save_stock_transfer_document(
            NULL,NULL,
            '00000000-0000-0000-0000-000000055041',
            '00000000-0000-0000-0000-000000055042',
            CURRENT_DATE,'G55 contender ' || v_i,
            jsonb_build_array(jsonb_build_object(
                'productId','00000000-0000-0000-0000-000000055031',
                'quantityBase',1
            ))
        );
        v_competing_id := (v_result->>'documentId')::UUID;
        BEGIN
            PERFORM public.post_stock_transfer(
                v_competing_id,1,gen_random_uuid()
            );
            v_success := v_success + 1;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM IN ('INSUFFICIENT_STOCK','INSUFFICIENT_FIFO_STOCK') THEN
                v_rejected_count := v_rejected_count + 1;
                IF EXISTS (
                    SELECT 1 FROM public.stock_transfer_documents
                    WHERE id = v_competing_id AND status <> 'DRAFT'
                ) OR EXISTS (
                    SELECT 1 FROM public.stock_movements
                    WHERE reference_table = 'stock_transfer_documents'
                      AND reference_id = v_competing_id
                ) THEN
                    RAISE EXCEPTION
                        'TEST_FAILED: rejected contender partially persisted';
                END IF;
            ELSE
                RAISE;
            END IF;
        END;
    END LOOP;
    IF v_success <> 5 OR v_rejected_count <> 15 THEN
        RAISE EXCEPTION
            'TEST_FAILED: contention result success %, rejected %',
            v_success,v_rejected_count;
    END IF;

    SELECT stock_qty INTO v_qty
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000055001'
      AND product_id = '00000000-0000-0000-0000-000000055031'
      AND warehouse_id = '00000000-0000-0000-0000-000000055041';
    IF v_qty <> 0 THEN
        RAISE EXCEPTION
            'TEST_FAILED: source balance %, expected 0',v_qty;
    END IF;
    SELECT stock_qty INTO v_qty
    FROM public.product_stocks
    WHERE company_id = '00000000-0000-0000-0000-000000055001'
      AND product_id = '00000000-0000-0000-0000-000000055031'
      AND warehouse_id = '00000000-0000-0000-0000-000000055042';
    IF v_qty <> 13 THEN
        RAISE EXCEPTION
            'TEST_FAILED: destination balance %, expected 13',v_qty;
    END IF;

    -- Final three-way reconciliation: balance = Movement aggregate = FIFO.
    SELECT count(*) INTO v_count
    FROM (
        SELECT
            ps.company_id,ps.product_id,ps.warehouse_id,
            ps.stock_qty,
            COALESCE((
                SELECT sum(sm.qty_change)
                FROM public.stock_movements sm
                WHERE sm.company_id = ps.company_id
                  AND sm.product_id = ps.product_id
                  AND sm.warehouse_id = ps.warehouse_id
                  AND sm.movement_status = 'POSTED'
            ),0) AS movement_qty,
            COALESCE((
                SELECT sum(pb.qty_remaining)
                FROM public.product_batches pb
                WHERE pb.company_id = ps.company_id
                  AND pb.product_id = ps.product_id
                  AND pb.warehouse_id = ps.warehouse_id
            ),0) AS fifo_qty
        FROM public.product_stocks ps
        WHERE ps.company_id = '00000000-0000-0000-0000-000000055001'
          AND ps.product_id = '00000000-0000-0000-0000-000000055031'
    ) reconciliation
    WHERE stock_qty <> movement_qty OR stock_qty <> fifo_qty;
    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'TEST_FAILED: final balance/Movement/FIFO mismatch';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.product_stocks WHERE product_id = v_bundle_id
        UNION ALL
        SELECT 1 FROM public.product_batches WHERE product_id = v_bundle_id
        UNION ALL
        SELECT 1 FROM public.stock_movements WHERE product_id = v_bundle_id
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Bundle acquired physical stock';
    END IF;
    IF (
        public.get_bundle_availability(
            v_bundle_id,
            '00000000-0000-0000-0000-000000055041'
        )->>'availableQuantity'
    )::BIGINT <> 0 OR (
        public.get_bundle_availability(
            v_bundle_id,
            '00000000-0000-0000-0000-000000055042'
        )->>'availableQuantity'
    )::BIGINT <> 6 THEN
        RAISE EXCEPTION
            'TEST_FAILED: final Bundle availability invalid';
    END IF;

    IF has_table_privilege(
        'authenticated','public.product_stocks','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.product_batches','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.stock_movements','INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: browser stock write boundary reopened';
    END IF;

    RAISE NOTICE
        'TEST PASSED: inventory core preserves two-layer FIFO, idempotent retry, atomic contention rejection, three-way reconciliation, and virtual Bundle availability.';
END
$test$;

ROLLBACK;

Okay clearly the fun project yeah project under pen projecting original project yeah plus come on seven yeah by your planting set oh yeah hello hello hello are in same yeah plus nanti process carrying process yeah ninety chat okay clear addition yeah limapi then the terminal like this pain
-- SAFETY: all Return/stock/refund/event fixtures are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID;
    v_sale_id UUID;
    v_detail_id UUID;
    v_sale public.sales_headers%ROWTYPE;
    v_detail public.sales_details%ROWTYPE;
    v_session public.cashier_sessions%ROWTYPE;
    v_cash_method public.payment_methods%ROWTYPE;
    v_result JSONB;
    v_cancel_id UUID;
    v_document_id UUID;
    v_refund NUMERIC(20,4);
    v_expected_before NUMERIC;
    v_expected_after NUMERIC;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    SELECT sale.id,detail.id INTO v_sale_id,v_detail_id
    FROM public.sales_headers sale
    JOIN public.sales_details detail
      ON detail.company_id=sale.company_id AND detail.sales_id=sale.id
    JOIN public.sale_stock_requirements requirement
      ON requirement.company_id=detail.company_id
     AND requirement.sales_detail_id=detail.id
    WHERE sale.document_status='POSTED'
      AND detail.qty>0
      AND detail.line_total+detail.allocated_document_rounding>0
      AND NOT EXISTS (
          SELECT 1
          FROM public.sales_return_lines return_line
          JOIN public.sales_return_documents return_document
            ON return_document.company_id=return_line.company_id
           AND return_document.id=return_line.document_id
           AND return_document.status='POSTED'
          WHERE return_line.company_id=detail.company_id
            AND return_line.source_sales_detail_id=detail.id
      )
    ORDER BY sale.posted_at,sale.id,detail.id LIMIT 1;
    IF v_sale_id IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: untouched posted stock Sale line required';
    END IF;
    SELECT * INTO v_sale FROM public.sales_headers WHERE id=v_sale_id;
    SELECT * INTO v_detail FROM public.sales_details WHERE id=v_detail_id;
    v_company:=v_sale.company_id;

    SELECT * INTO v_session FROM public.cashier_sessions
    WHERE company_id=v_company AND store_id=v_sale.store_id
      AND status='OPEN'::public.session_status
    ORDER BY opened_at DESC,id LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: open Session in source Store required';
    END IF;
    SELECT * INTO v_cash_method FROM public.payment_methods method
    WHERE method.company_id=v_company AND method.is_active
      AND method.method_type='CASH'
      AND method.effective_from<=clock_timestamp()
      AND (method.effective_to IS NULL
           OR method.effective_to>=clock_timestamp())
      AND (
          method.available_all_stores OR EXISTS (
              SELECT 1 FROM public.payment_method_store_assignments assignment
              WHERE assignment.company_id=method.company_id
                AND assignment.payment_method_id=method.id
                AND assignment.store_id=v_sale.store_id
          )
      )
    ORDER BY method.is_default DESC,method.id LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: eligible Cash method required';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.transaction_categories category
        WHERE category.company_id=v_company
          AND category.system_key='SALES_RETURN'
          AND category.is_active AND category.is_system_default
    ) THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: Sales Return category required';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE26_TEST');

    v_refund:=round(
        v_detail.line_total+v_detail.allocated_document_rounding,4
    );
    IF NOT EXISTS (
        SELECT 1 FROM public.sales_details other
        WHERE other.company_id=v_company AND other.sales_id=v_sale.id
          AND other.id<>v_detail.id
    ) THEN
        v_refund:=v_sale.grand_total_after_rounding;
    END IF;

    -- Draft cancellation has no stock/event effect.
    v_result:=public.save_sales_return_draft(
        NULL,NULL,v_sale.id,v_session.id,'NONE','Disposable cancel test',
        jsonb_build_array(jsonb_build_object(
            'sourceSalesDetailId',v_detail.id,'quantity',v_detail.qty,
            'condition','SALEABLE'
        )),
        jsonb_build_array(jsonb_build_object(
            'clientRefundKey',gen_random_uuid(),
            'paymentMethodId',v_cash_method.id,'amount',v_refund
        ))
    );
    v_cancel_id:=(v_result->>'documentId')::UUID;
    v_result:=public.cancel_sales_return_draft(
        v_cancel_id,1,'Disposable cancellation'
    );
    IF v_result->>'status'<>'CANCELED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Return draft was not canceled';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.stock_movements
        WHERE reference_table='sales_return_documents'
          AND reference_id=v_cancel_id
    ) OR EXISTS (
        SELECT 1 FROM public.financial_events
        WHERE source_table='sales_return_documents' AND source_id=v_cancel_id
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: canceled draft produced final effect';
    END IF;

    v_expected_before:=private.calculate_cashier_session_expected_cash(
        v_company,v_session.id
    );
    v_result:=public.save_sales_return_draft(
        NULL,NULL,v_sale.id,v_session.id,'NONE','Disposable posted test',
        jsonb_build_array(jsonb_build_object(
            'sourceSalesDetailId',v_detail.id,'quantity',v_detail.qty,
            'condition','SALEABLE'
        )),
        jsonb_build_array(jsonb_build_object(
            'clientRefundKey',gen_random_uuid(),
            'paymentMethodId',v_cash_method.id,'amount',v_refund
        ))
    );
    v_document_id:=(v_result->>'documentId')::UUID;
    v_result:=public.post_sales_return(
        v_document_id,(v_result->>'masterVersion')::BIGINT,
        '00000000-0000-0000-0000-000000026001'
    );
    IF v_result->>'status'<>'POSTED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Sales Return was not posted';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.sales_return_fifo_restorations restoration
    WHERE restoration.document_id=v_document_id;
    IF v_count=0 THEN
        RAISE EXCEPTION 'TEST_FAILED: FIFO restoration missing';
    END IF;
    SELECT count(*) INTO v_count FROM public.stock_movements movement
    WHERE movement.reference_table='sales_return_documents'
      AND movement.reference_id=v_document_id
      AND movement.movement_type='SALES_RETURN'::public.stock_movement_type;
    IF v_count=0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Sales Return movement missing';
    END IF;
    SELECT count(*) INTO v_count FROM public.financial_events event
    WHERE event.source_table='sales_return_documents'
      AND event.source_id=v_document_id
      AND event.root_sales_id=v_sale.id
      AND event.system_event_key='SALES_RETURN'
      AND event.status='HOLD'::public.event_status;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Return Finance HOLD event missing';
    END IF;
    v_expected_after:=private.calculate_cashier_session_expected_cash(
        v_company,v_session.id
    );
    IF v_expected_after<>v_expected_before-v_refund THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash refund not reflected in Session';
    END IF;

    -- Same posting identity replays one final effect.
    v_result:=public.post_sales_return(
        v_document_id,(v_result->>'masterVersion')::BIGINT,
        '00000000-0000-0000-0000-000000026001'
    );
    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: Return replay was not idempotent';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_sales_return_draft(
            NULL,NULL,v_sale.id,v_session.id,'NONE','Excess Return',
            jsonb_build_array(jsonb_build_object(
                'sourceSalesDetailId',v_detail.id,'quantity',v_detail.qty,
                'condition','SALEABLE'
            )),
            jsonb_build_array(jsonb_build_object(
                'paymentMethodId',v_cash_method.id,'amount',v_refund
            ))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='RETURN_QUANTITY_EXCEEDS_REFUNDABLE' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cumulative over-Return accepted';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        UPDATE public.sales_return_documents SET notes='Forbidden edit'
        WHERE id=v_document_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='FINAL_SALES_RETURN_IMMUTABLE' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: posted Return mutated';
    END IF;

    IF has_table_privilege(
        'authenticated','public.sales_return_documents','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.sales_return_lines','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.sales_return_refunds','INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: direct Return write boundary open';
    END IF;

    RAISE NOTICE 'TEST PASSED: Sales Return is source-bound, cumulative-safe, FIFO-restoring, refund-balanced, idempotent, immutable, and audited.';
END
$test$;

ROLLBACK;

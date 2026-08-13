-- G6 phase 7B persistent Finance UAT dataset.
--
-- WARNING: THIS FILE CREATES REAL, IMMUTABLE UAT BUSINESS HISTORY.
-- Run only in a test/pilot database after the companion preflight is all PASS.
-- It intentionally uses guarded business RPCs; it never inserts a final
-- Finance journal, Stock balance, FIFO batch, or Stock Movement directly.
--
-- Expected final state:
-- - UAT-FIN-001 stock = 105 base units at Rp50,000/unit;
-- - Opening Stock Rp5,000,000 is POSTED through the controlled Finance queue;
-- - Stock Gain Rp250,000 remains HOLD for Pending Analysis because that
--   posting contract is intentionally deferred.

BEGIN;

DO $uat_seed$
DECLARE
    v_actor UUID;
    v_company UUID;
    v_category UUID;
    v_uom UUID;
    v_warehouse UUID;
    v_product UUID;
    v_reason UUID;
    v_opening_document UUID;
    v_opening_event UUID;
    v_adjustment_document UUID;
    v_adjustment_event UUID;
    v_queue UUID;
    v_journal UUID;
    v_result JSONB;
    v_version BIGINT;
    v_count BIGINT;
BEGIN
    SELECT count(*),min(company.id::TEXT)::UUID
    INTO v_count,v_company
    FROM public.companies company
    WHERE company.status='ACTIVE';
    IF v_count<>1 OR v_company IS NULL THEN
        RAISE EXCEPTION
            'UAT_SEED_REQUIRES_EXACTLY_ONE_ACTIVE_COMPANY: found %',v_count;
    END IF;

    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role::TEXT='super_admin'
    ORDER BY profile.id
    LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'UAT_SEED_LINKED_SUPER_ADMIN_REQUIRED';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.products product
        WHERE product.company_id=v_company
          AND (
              upper(btrim(product.sku))='UAT-FIN-001'
              OR lower(regexp_replace(
                  btrim(product.name),'\s+',' ','g'
              ))='uat finance product'
          )
    ) THEN
        RAISE EXCEPTION
            'UAT_DATASET_ALREADY_EXISTS: do not duplicate immutable history';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.finance_posting_queue_runs run
        WHERE run.company_id=v_company
          AND run.status IN ('PREVIEWED','APPROVED','PROCESSING')
    ) THEN
        RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.financial_events event
        WHERE event.company_id=v_company
          AND event.status::TEXT='HOLD'
          AND event.system_event_key='STOCK_OPENING'
          AND event.event_type::TEXT='STOCK_OPENING'
          AND event.source_table='opening_stock_documents'
          AND NOT EXISTS (
              SELECT 1 FROM public.finance_journals journal
              WHERE journal.company_id=event.company_id
                AND journal.financial_event_id=event.id
          )
    ) THEN
        RAISE EXCEPTION
            'EXISTING_SUPPORTED_HOLD_EVENT: queue scope would not be isolated';
    END IF;

    SELECT category.id INTO v_category
    FROM public.product_categories category
    WHERE category.company_id=v_company AND category.is_active
    ORDER BY category.created_at,category.id
    LIMIT 1;
    SELECT uom.id INTO v_uom
    FROM public.uoms uom
    WHERE uom.company_id=v_company AND uom.is_active
    ORDER BY uom.created_at,uom.id
    LIMIT 1;
    SELECT warehouse.id INTO v_warehouse
    FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.is_active
    ORDER BY
        CASE WHEN warehouse.store_id IS NOT NULL THEN 0 ELSE 1 END,
        warehouse.created_at,warehouse.id
    LIMIT 1;
    IF v_category IS NULL OR v_uom IS NULL OR v_warehouse IS NULL THEN
        RAISE EXCEPTION
            'UAT_SEED_MASTER_NOT_READY: Category, UOM, and Warehouse required';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G6_UAT_SEED');

    v_result:=public.save_product_with_uoms(
        NULL,NULL,'UAT-FIN-001','UAT Finance Product',v_category,
        v_uom,v_uom,1,FALSE,NULL,TRUE,
        jsonb_build_array(jsonb_build_object(
            'uomId',v_uom,
            'factorToBase',1,
            'purchaseAllowed',TRUE,
            'salesAllowed',TRUE,
            'purchasePrice',50000,
            'salePrice',75000,
            'isActive',TRUE
        ))
    );
    v_product:=(v_result->>'productId')::UUID;

    v_result:=public.save_opening_stock_document(
        NULL,NULL,v_warehouse,CURRENT_DATE,
        'UAT Finance: opening stock Rp5.000.000',
        jsonb_build_array(jsonb_build_object(
            'productId',v_product,
            'quantityBase',100,
            'unitCostBase',50000,
            'notes','UAT seed generated through guarded Opening Stock RPC'
        ))
    );
    v_opening_document:=(v_result->>'documentId')::UUID;
    v_version:=(v_result->>'masterVersion')::BIGINT;
    v_result:=public.post_opening_stock(
        v_opening_document,v_version,
        '76000000-0000-0000-0000-000000000001'::UUID
    );
    v_opening_event:=(v_result->>'financialEventId')::UUID;

    v_result:=public.preview_financial_event_posting_queue(1);
    IF (v_result->>'eventCount')::BIGINT<>1 THEN
        RAISE EXCEPTION 'UAT_QUEUE_SCOPE_INVALID';
    END IF;
    v_queue:=(v_result->>'queueRunId')::UUID;
    v_version:=(v_result->>'masterVersion')::BIGINT;
    SELECT count(*) INTO v_count
    FROM public.finance_posting_queue_items item
    WHERE item.company_id=v_company
      AND item.queue_run_id=v_queue
      AND item.financial_event_id=v_opening_event;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'UAT_QUEUE_EVENT_MISMATCH';
    END IF;
    v_result:=public.approve_financial_event_posting_queue(v_queue,v_version);
    v_version:=(v_result->>'masterVersion')::BIGINT;
    v_result:=public.process_financial_event_posting_queue(v_queue,v_version);
    IF v_result->>'status'<>'COMPLETED'
       OR (v_result->>'postedCount')::BIGINT<>1
       OR (v_result->>'failedCount')::BIGINT<>0
       OR (v_result->>'skippedCount')::BIGINT<>0 THEN
        RAISE EXCEPTION 'UAT_QUEUE_PROCESS_FAILED: %',v_result;
    END IF;
    SELECT journal.id INTO v_journal
    FROM public.finance_journals journal
    WHERE journal.company_id=v_company
      AND journal.financial_event_id=v_opening_event
      AND journal.status='POSTED';
    IF v_journal IS NULL THEN
        RAISE EXCEPTION 'UAT_OPENING_JOURNAL_NOT_POSTED';
    END IF;

    SELECT reason.id INTO v_reason
    FROM public.stock_adjustment_reasons reason
    WHERE reason.company_id=v_company
      AND lower(regexp_replace(
          btrim(reason.reason_name),'\s+',' ','g'
      ))='uat selisih lebih finance'
    ORDER BY reason.id
    LIMIT 1;
    IF v_reason IS NULL THEN
        v_result:=public.save_stock_adjustment_reason(
            NULL,NULL,'UAT Selisih Lebih Finance',
            'INCREASE','STOCK_GAIN',TRUE
        );
        v_reason:=(v_result->>'reasonId')::UUID;
    END IF;

    v_result:=public.save_stock_adjustment_document(
        NULL,NULL,v_warehouse,CURRENT_DATE,
        'UAT Finance: physical count 105, system stock 100',
        jsonb_build_array(jsonb_build_object(
            'productId',v_product,
            'reasonId',v_reason,
            'finalPhysicalQuantity',105,
            'unitCostBase',50000,
            'notes','UAT seed generates a deferred STOCK_GAIN Finance event'
        ))
    );
    v_adjustment_document:=(v_result->>'documentId')::UUID;
    v_version:=(v_result->>'masterVersion')::BIGINT;
    v_result:=public.post_stock_adjustment(
        v_adjustment_document,v_version,
        '76000000-0000-0000-0000-000000000002'::UUID
    );
    v_adjustment_event:=(v_result->>'gainFinancialEventId')::UUID;
    IF v_adjustment_event IS NULL THEN
        RAISE EXCEPTION 'UAT_STOCK_GAIN_EVENT_NOT_CREATED';
    END IF;

    RAISE NOTICE
        'UAT DATASET CREATED: product %, opening %, journal %, adjustment %, pending event %',
        v_product,v_opening_document,v_journal,v_adjustment_document,
        v_adjustment_event;
END
$uat_seed$;

COMMIT;

SELECT
    product.sku AS product_sku,
    product.name AS product_name,
    warehouse.name AS warehouse_name,
    stock.stock_qty AS actual_stock_base,
    opening.document_no AS opening_stock_no,
    journal.display_no AS posted_journal_no,
    queue.display_no AS posting_queue_no,
    adjustment.document_no AS adjustment_no,
    event.status AS stock_gain_finance_status,
    (event.amounts->>'inventoryDebit')::NUMERIC AS stock_gain_value
FROM public.products product
JOIN public.product_stocks stock
  ON stock.company_id=product.company_id AND stock.product_id=product.id
JOIN public.warehouses warehouse
  ON warehouse.company_id=stock.company_id AND warehouse.id=stock.warehouse_id
JOIN public.opening_stock_lines opening_line
  ON opening_line.company_id=product.company_id
 AND opening_line.product_id=product.id
JOIN public.opening_stock_documents opening
  ON opening.company_id=opening_line.company_id
 AND opening.id=opening_line.document_id
JOIN public.financial_events opening_event
  ON opening_event.company_id=opening.company_id
 AND opening_event.id=opening.financial_event_id
JOIN public.finance_journals journal
  ON journal.company_id=opening_event.company_id
 AND journal.financial_event_id=opening_event.id
JOIN public.finance_posting_queue_items queue_item
  ON queue_item.company_id=opening_event.company_id
 AND queue_item.financial_event_id=opening_event.id
JOIN public.finance_posting_queue_runs queue
  ON queue.company_id=queue_item.company_id
 AND queue.id=queue_item.queue_run_id
JOIN public.stock_adjustment_lines adjustment_line
  ON adjustment_line.company_id=product.company_id
 AND adjustment_line.product_id=product.id
JOIN public.stock_adjustment_documents adjustment
  ON adjustment.company_id=adjustment_line.company_id
 AND adjustment.id=adjustment_line.document_id
JOIN public.financial_events event
  ON event.company_id=adjustment.company_id
 AND event.id=adjustment.gain_financial_event_id
WHERE upper(btrim(product.sku))='UAT-FIN-001';

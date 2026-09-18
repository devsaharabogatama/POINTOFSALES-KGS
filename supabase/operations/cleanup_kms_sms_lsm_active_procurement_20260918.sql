-- One-time guarded cleanup for KMS, SMS, and LSM active Purchase documents.
--
-- Approved boundary:
--   * keep replenishment mode AUTO_RO;
--   * retain received KMS PO PO-20260825-0000000015 as immutable history;
--   * cancel exactly 52 zero-net-receipt Supplier Orders through the canonical
--     cancellation runtime;
--   * close exactly 95 old SUBMITTED/ORDERED Stock Request headers through the
--     canonical close runtime so they no longer cover current negative On Hand;
--   * never mutate Stock/FIFO, Finance, Sales, line, or allocation history.
--
-- This operation is pinned to the Production preflight supplied on 2026-09-18.
-- Any drift raises an exception and rolls the whole transaction back.

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

DROP TABLE IF EXISTS pg_temp.cleanup_execution_result;
DROP TABLE IF EXISTS pg_temp.cleanup_protected_digest;
DROP TABLE IF EXISTS pg_temp.cleanup_target_company;

CREATE TEMP TABLE cleanup_target_company(
  company_id uuid PRIMARY KEY,
  expected_name text NOT NULL,
  short_code text NOT NULL UNIQUE
) ON COMMIT PRESERVE ROWS;

INSERT INTO cleanup_target_company(company_id,expected_name,short_code) VALUES
  ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8','Khadijah Muda Sejahtera','KMS'),
  ('809abdd9-d05f-4525-9726-1951a0ae1a81','Smart Muda Solusi','SMS'),
  ('07bdffb9-8c56-444c-a49b-81ac86745674','Latorti Sari Median','LSM');

CREATE TEMP TABLE cleanup_protected_digest(
  table_name text PRIMARY KEY,
  row_count bigint NOT NULL,
  row_digest text NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE TEMP TABLE cleanup_execution_result(
  check_name text PRIMARY KEY,
  status text NOT NULL,
  details jsonb NOT NULL
) ON COMMIT PRESERVE ROWS;

DO $cleanup$
DECLARE
  v_actor uuid;
  v_original_context public.user_active_company_contexts%rowtype;
  v_had_original_context boolean:=false;
  v_company record;
  v_order record;
  v_request record;
  v_table text;
  v_count bigint;
  v_digest text;
  v_expected_digest text;
  v_po_canceled integer:=0;
  v_request_closed integer:=0;
  v_draft_receipts_before bigint:=0;
  v_draft_receipts_after bigint:=0;
  v_preview jsonb;
  v_preview_rows integer:=0;
  v_raw_negative numeric:=0;
  v_result jsonb;
  v_retained_order constant uuid:='2ea66e69-cd81-4d6c-81ea-e7619112f20b';
  v_reason constant text:='FULL_PROCUREMENT_CLEANUP_20260918';
  v_protected_tables constant text[]:=ARRAY[
    'public.product_stocks',
    'public.product_batches',
    'public.stock_movements',
    'public.goods_receipt_lines',
    'public.goods_receipt_condition_allocations',
    'public.goods_receipt_ap_provisionals',
    'public.purchase_return_documents',
    'public.purchase_return_lines',
    'public.stock_request_lines',
    'public.supplier_order_lines',
    'public.supplier_order_request_allocations',
    'public.supplier_invoice_documents',
    'public.supplier_invoice_allocations',
    'public.supplier_payment_documents',
    'public.supplier_payment_allocations',
    'public.financial_events',
    'public.finance_journals',
    'public.finance_journal_lines',
    'public.sales_headers',
    'public.sales_details',
    'public.sales_order_procurement_demand_lines'
  ];
BEGIN
  IF to_regprocedure(
      'private.cancel_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,text)') IS NULL
    OR to_regprocedure('private.acp5c_close_stock_request_core(uuid,bigint)') IS NULL
    OR to_regprocedure(
      'private.get_purchase_daily_replenishment_candidates_core(uuid,date)') IS NULL THEN
    RAISE EXCEPTION
      'CLEANUP_PRECONDITION_FAILED: canonical Purchase cancellation/close runtime missing';
  END IF;

  IF EXISTS(
    SELECT 1 FROM cleanup_target_company target
    LEFT JOIN public.companies company ON company.id=target.company_id
    LEFT JOIN public.company_purchase_replenishment_settings setting
      ON setting.company_id=target.company_id
    WHERE company.id IS NULL OR company.company_name<>target.expected_name
      OR company.status<>'ACTIVE' OR setting.company_id IS NULL
      OR setting.replenishment_mode<>'AUTO_RO'
  ) THEN
    RAISE EXCEPTION
      'CLEANUP_PRECONDITION_FAILED: exact Company identity or AUTO_RO mode drift';
  END IF;

  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'CLEANUP_PRECONDITION_FAILED: active Finance posting queue';
  END IF;

  IF EXISTS(
    SELECT 1 FROM cleanup_target_company target
    JOIN public.companies company ON company.id=target.company_id
    JOIN public.purchase_daily_scheduler_runs run
      ON run.company_id=target.company_id
     AND run.business_date=(clock_timestamp() AT TIME ZONE company.timezone)::date
    WHERE run.status IN('GENERATED','NO_DEMAND')
  ) THEN
    RAISE EXCEPTION
      'CLEANUP_PRECONDITION_FAILED: scheduler already completed for current Company date';
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.purchase_daily_batches batch
    WHERE batch.company_id IN(SELECT company_id FROM cleanup_target_company)
      AND batch.status<>'CANCELED'
  ) THEN
    RAISE EXCEPTION 'CLEANUP_PRECONDITION_FAILED: active daily RO appeared';
  END IF;

  SELECT count(*),md5(COALESCE(string_agg(
      document.id::text||'|'||document.status||'|'||document.master_version::text||
      '|'||document.order_no,',' ORDER BY document.id),''))
  INTO v_count,v_digest
  FROM public.supplier_order_documents document
  WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
    AND document.id<>v_retained_order
    AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED');
  IF v_count<>52 OR v_digest<>'a627b2c932f8855ce95c2da238f4fc05' THEN
    RAISE EXCEPTION
      'CLEANUP_SCOPE_DRIFT: expected 52 exact cancelable PO rows, got % digest %',
      v_count,v_digest;
  END IF;

  IF NOT EXISTS(
      SELECT 1 FROM public.supplier_order_documents document
      WHERE document.company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'
        AND document.id=v_retained_order
        AND document.order_no='PO-20260825-0000000015'
        AND document.status='RECEIVED' AND document.master_version=3
        AND private.purchase_supplier_order_net_received_base_qty(
          document.company_id,document.id)=202)
    OR EXISTS(
      SELECT 1 FROM public.supplier_order_documents document
      WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
        AND document.id<>v_retained_order
        AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
        AND private.purchase_supplier_order_net_received_base_qty(
          document.company_id,document.id)<>0)
  THEN
    RAISE EXCEPTION
      'CLEANUP_PRECONDITION_FAILED: retained PO or zero-net-receipt boundary drift';
  END IF;

  IF EXISTS(
    SELECT 1
    FROM public.supplier_order_documents document
    JOIN public.supplier_order_lines order_line
      ON order_line.company_id=document.company_id
     AND order_line.document_id=document.id
    JOIN public.supplier_invoice_allocations allocation
      ON allocation.company_id=order_line.company_id
     AND allocation.supplier_order_line_id=order_line.id
    JOIN public.supplier_invoice_documents invoice
      ON invoice.company_id=allocation.company_id
     AND invoice.id=allocation.document_id
    WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
      AND document.id<>v_retained_order
      AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
      AND invoice.status<>'CANCELED'
  ) THEN
    RAISE EXCEPTION 'CLEANUP_PRECONDITION_FAILED: cancelable PO has active Supplier Bill';
  END IF;

  SELECT count(*),md5(COALESCE(string_agg(
      document.id::text||'|'||document.status||'|'||document.master_version::text||
      '|'||document.request_no,',' ORDER BY document.id),''))
  INTO v_count,v_digest
  FROM public.stock_request_documents document
  WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
    AND document.status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED');
  IF v_count<>95 OR v_digest<>'a29857add5540f988baa5807e863c2a2' THEN
    RAISE EXCEPTION
      'CLEANUP_SCOPE_DRIFT: expected 95 exact active Stock Request headers, got % digest %',
      v_count,v_digest;
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.stock_request_documents document
    WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
      AND document.status IN('DRAFT','PARTIALLY_RECEIVED')
  ) THEN
    RAISE EXCEPTION
      'CLEANUP_PRECONDITION_FAILED: Stock Request status needs a different canonical transition';
  END IF;

  SELECT profile.id INTO v_actor
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role::text='super_admin' AND auth_user.deleted_at IS NULL
  ORDER BY profile.id
  LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'CLEANUP_PRECONDITION_FAILED: linked Super Admin actor required';
  END IF;

  SELECT * INTO v_original_context
  FROM public.user_active_company_contexts context
  WHERE context.user_id=v_actor FOR UPDATE;
  v_had_original_context:=FOUND;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);

  FOREACH v_table IN ARRAY v_protected_tables LOOP
    IF to_regclass(v_table) IS NULL THEN
      RAISE EXCEPTION 'CLEANUP_PRECONDITION_FAILED: protected table % missing',v_table;
    END IF;
    EXECUTE format(
      'SELECT count(*),md5(COALESCE(string_agg(md5(to_jsonb(row_data)::text),'','' '
      ||'ORDER BY md5(to_jsonb(row_data)::text)),'''')) FROM %s row_data '
      ||'WHERE company_id=ANY($1)',v_table)
    INTO v_count,v_digest
    USING ARRAY(SELECT company_id FROM cleanup_target_company ORDER BY company_id);
    INSERT INTO cleanup_protected_digest(table_name,row_count,row_digest)
    VALUES(v_table,v_count,v_digest);
  END LOOP;

  SELECT count(*),md5(COALESCE(string_agg(
    md5(to_jsonb(receipt)::text),',' ORDER BY md5(to_jsonb(receipt)::text)),''))
  INTO v_count,v_digest
  FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id IN(SELECT company_id FROM cleanup_target_company)
    AND receipt.status='POSTED';
  INSERT INTO cleanup_protected_digest(table_name,row_count,row_digest)
  VALUES('public.goods_receipt_documents[POSTED]',v_count,v_digest);

  SELECT count(*) INTO v_draft_receipts_before
  FROM public.goods_receipt_documents receipt
  JOIN public.supplier_order_documents document
    ON document.company_id=receipt.company_id AND document.id=receipt.supplier_order_id
  WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
    AND document.id<>v_retained_order
    AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    AND receipt.status='DRAFT';

  FOR v_company IN
    SELECT * FROM cleanup_target_company ORDER BY short_code
  LOOP
    INSERT INTO public.user_active_company_contexts(
      user_id,company_id,selection_source,selected_at,updated_at)
    VALUES(v_actor,v_company.company_id,'CONTROLLED_CLEANUP',
      clock_timestamp(),clock_timestamp())
    ON CONFLICT(user_id) DO UPDATE SET
      company_id=excluded.company_id,
      selection_source=excluded.selection_source,
      selected_at=excluded.selected_at,
      updated_at=excluded.updated_at;

    FOR v_order IN
      SELECT document.id,document.master_version
      FROM public.supplier_order_documents document
      WHERE document.company_id=v_company.company_id
        AND document.id<>v_retained_order
        AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
      ORDER BY document.id FOR UPDATE
    LOOP
      v_result:=private.cancel_purchase_supplier_order_core(
        v_company.company_id,v_order.id,v_order.master_version,
        md5('FULL_PROCUREMENT_CLEANUP_20260918|'||v_order.id::text)::uuid,
        v_actor,v_reason);
      IF v_result->>'status'<>'CANCELED' THEN
        RAISE EXCEPTION 'CLEANUP_RUNTIME_FAILED: PO % did not cancel',v_order.id;
      END IF;
      v_po_canceled:=v_po_canceled+1;
    END LOOP;

    FOR v_request IN
      SELECT document.id,document.master_version,document.status
      FROM public.stock_request_documents document
      WHERE document.company_id=v_company.company_id
        AND document.status IN('SUBMITTED','ORDERED')
      ORDER BY document.id FOR UPDATE
    LOOP
      v_result:=private.acp5c_close_stock_request_core(
        v_request.id,v_request.master_version);
      IF v_result->>'status'<>'CLOSED' THEN
        RAISE EXCEPTION 'CLEANUP_RUNTIME_FAILED: Stock Request % did not close',v_request.id;
      END IF;
      v_request_closed:=v_request_closed+1;
    END LOOP;
  END LOOP;

  IF v_had_original_context THEN
    UPDATE public.user_active_company_contexts SET
      company_id=v_original_context.company_id,
      selection_source=v_original_context.selection_source,
      selected_at=v_original_context.selected_at,
      updated_at=v_original_context.updated_at
    WHERE user_id=v_actor;
  ELSE
    DELETE FROM public.user_active_company_contexts WHERE user_id=v_actor;
  END IF;

  IF v_po_canceled<>52 OR v_request_closed<>95 THEN
    RAISE EXCEPTION
      'CLEANUP_RUNTIME_FAILED: expected 52 PO and 95 Stock Requests, got % and %',
      v_po_canceled,v_request_closed;
  END IF;

  SELECT count(*) INTO v_draft_receipts_after
  FROM public.goods_receipt_documents receipt
  JOIN public.supplier_order_documents document
    ON document.company_id=receipt.company_id AND document.id=receipt.supplier_order_id
  WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
    AND document.id<>v_retained_order AND receipt.status='DRAFT';
  IF v_draft_receipts_after<>0 THEN
    RAISE EXCEPTION
      'CLEANUP_RECONCILIATION_FAILED: Draft Goods Receipt remains for canceled PO';
  END IF;

  IF EXISTS(
      SELECT 1 FROM public.supplier_order_documents document
      WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
        AND document.id<>v_retained_order
        AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED'))
    OR EXISTS(
      SELECT 1 FROM public.stock_request_documents document
      WHERE document.company_id IN(SELECT company_id FROM cleanup_target_company)
        AND document.status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED'))
    OR EXISTS(
      SELECT 1 FROM public.purchase_daily_batches batch
      WHERE batch.company_id IN(SELECT company_id FROM cleanup_target_company)
        AND batch.status<>'CANCELED')
  THEN
    RAISE EXCEPTION 'CLEANUP_RECONCILIATION_FAILED: old active coverage remains';
  END IF;

  IF NOT EXISTS(
    SELECT 1 FROM public.supplier_order_documents document
    WHERE document.company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'
      AND document.id=v_retained_order AND document.status='RECEIVED'
      AND document.master_version=3
      AND private.purchase_supplier_order_net_received_base_qty(
        document.company_id,document.id)=202
  ) THEN
    RAISE EXCEPTION 'CLEANUP_RECONCILIATION_FAILED: retained received PO changed';
  END IF;

  FOREACH v_table IN ARRAY v_protected_tables LOOP
    EXECUTE format(
      'SELECT count(*),md5(COALESCE(string_agg(md5(to_jsonb(row_data)::text),'','' '
      ||'ORDER BY md5(to_jsonb(row_data)::text)),'''')) FROM %s row_data '
      ||'WHERE company_id=ANY($1)',v_table)
    INTO v_count,v_digest
    USING ARRAY(SELECT company_id FROM cleanup_target_company ORDER BY company_id);
    SELECT row_digest INTO v_expected_digest
    FROM cleanup_protected_digest WHERE table_name=v_table AND row_count=v_count;
    IF v_expected_digest IS NULL OR v_digest<>v_expected_digest THEN
      RAISE EXCEPTION
        'CLEANUP_PROTECTED_DATA_CHANGED: % count % digest %',v_table,v_count,v_digest;
    END IF;
  END LOOP;

  SELECT count(*),md5(COALESCE(string_agg(
    md5(to_jsonb(receipt)::text),',' ORDER BY md5(to_jsonb(receipt)::text)),''))
  INTO v_count,v_digest
  FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id IN(SELECT company_id FROM cleanup_target_company)
    AND receipt.status='POSTED';
  SELECT row_digest INTO v_expected_digest
  FROM cleanup_protected_digest
  WHERE table_name='public.goods_receipt_documents[POSTED]' AND row_count=v_count;
  IF v_expected_digest IS NULL OR v_digest<>v_expected_digest THEN
    RAISE EXCEPTION
      'CLEANUP_PROTECTED_DATA_CHANGED: Posted Goods Receipt count % digest %',
      v_count,v_digest;
  END IF;

  IF EXISTS(
    SELECT 1 FROM cleanup_target_company target
    JOIN public.companies company ON company.id=target.company_id
    CROSS JOIN LATERAL (SELECT
      private.get_purchase_daily_replenishment_candidates_core(
        target.company_id,(clock_timestamp() AT TIME ZONE company.timezone)::date)
        AS payload
    ) preview
    CROSS JOIN LATERAL jsonb_array_elements(preview.payload->'candidates') candidate
    WHERE COALESCE((candidate->>'openSupplierOrderBaseQty')::numeric,0)<>0
       OR COALESCE((candidate->>'openExactRequestBaseQty')::numeric,0)<>0
       OR COALESCE((candidate->>'ambiguousOpenRequestBaseQty')::numeric,0)<>0
       OR COALESCE((candidate->>'requestedBaseQty')::numeric,0)
          <>-COALESCE((candidate->>'onHandBaseQty')::numeric,0)
  ) THEN
    RAISE EXCEPTION
      'CLEANUP_RECONCILIATION_FAILED: candidate does not equal current negative On Hand';
  END IF;

  FOR v_company IN
    SELECT target.*,company.timezone
    FROM cleanup_target_company target
    JOIN public.companies company ON company.id=target.company_id
    ORDER BY target.short_code
  LOOP
    v_preview:=private.get_purchase_daily_replenishment_candidates_core(
      v_company.company_id,(clock_timestamp() AT TIME ZONE v_company.timezone)::date);
    v_preview_rows:=v_preview_rows+COALESCE(
      (v_preview->'summary'->>'negativeOnHandRows')::integer,0);
    SELECT v_raw_negative+COALESCE(sum(
      (candidate->>'requestedBaseQty')::numeric),0)
    INTO v_raw_negative
    FROM jsonb_array_elements(v_preview->'candidates') candidate;
  END LOOP;

  INSERT INTO cleanup_execution_result(check_name,status,details) VALUES
    ('controlled_cleanup','PASS',jsonb_build_object(
      'actorId',v_actor,
      'canceledSupplierOrders',v_po_canceled,
      'closedStockRequests',v_request_closed,
      'canceledDraftGoodsReceipts',v_draft_receipts_before,
      'retainedReceivedOrder','PO-20260825-0000000015',
      'retainedReceivedBaseQty',202,
      'replenishmentMode','AUTO_RO',
      'nextAutomaticDocument','Daily RO; user confirmation creates PO')),
    ('stock_finance_integrity','PASS',jsonb_build_object(
      'protectedTables',array_length(v_protected_tables,1)+1,
      'comparison','Exact target-Company row count and full-row digest before/after')),
    ('next_auto_ro_candidate','PASS',jsonb_build_object(
      'negativeOnHandRows',v_preview_rows,
      'requestedBaseQty',v_raw_negative,
      'openSupplierOrderBaseQty',0,
      'openStockRequestBaseQty',0));
END
$cleanup$;

COMMIT;

SELECT check_name,status,details
FROM cleanup_execution_result
ORDER BY check_name;

-- PO cancellation readiness after source-linked Backoffice Supplier Return.
BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919141000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Purchase Return Finance runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919142000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260919142000';
  END IF;
  IF to_regprocedure('public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure('private.cancel_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: PO cancellation runtime drift';
  END IF;
  IF to_regprocedure('public.get_purchase_supplier_order_return_readiness(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: PO Return readiness collision';
  END IF;
END
$guard$;

CREATE FUNCTION private.purchase_supplier_order_return_readiness_core(
  p_company_id uuid,p_order_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_order public.supplier_order_documents%rowtype;v_net numeric(24,6);
  v_draft_returns bigint;v_draft_bills bigint;v_invalid_finance bigint;
  v_refund_receivable numeric(20,4);v_return_rows bigint;
BEGIN
  SELECT * INTO v_order FROM public.supplier_order_documents document
  WHERE document.company_id=p_company_id AND document.id=p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;
  v_net:=private.purchase_supplier_order_net_received_base_qty(p_company_id,p_order_id);
  SELECT count(*) INTO v_draft_returns FROM public.purchase_return_documents document
  WHERE document.company_id=p_company_id AND document.supplier_order_id=p_order_id
    AND document.status='DRAFT';
  SELECT count(DISTINCT invoice.id) INTO v_draft_bills
  FROM public.supplier_invoice_documents invoice
  JOIN public.supplier_invoice_allocations allocation
    ON allocation.company_id=invoice.company_id AND allocation.document_id=invoice.id
  JOIN public.supplier_order_lines order_line
    ON order_line.company_id=allocation.company_id
   AND order_line.id=allocation.supplier_order_line_id
  WHERE invoice.company_id=p_company_id AND order_line.document_id=p_order_id
    AND invoice.status IN('DRAFT','HOLD');
  SELECT count(*) INTO v_invalid_finance
  FROM public.purchase_return_documents return_document
  WHERE return_document.company_id=p_company_id
    AND return_document.supplier_order_id=p_order_id
    AND return_document.status='POSTED'
    AND return_document.source_channel='BACKOFFICE'
    AND (return_document.financial_event_id IS NULL
      OR NOT EXISTS(SELECT 1 FROM public.financial_events event
        WHERE event.company_id=return_document.company_id
          AND event.id=return_document.financial_event_id
          AND event.status='POSTED'::public.event_status)
      OR NOT EXISTS(SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id=return_document.company_id
          AND journal.financial_event_id=return_document.financial_event_id
          AND journal.status='POSTED' AND journal.total_debit=journal.total_credit)
      OR EXISTS(SELECT 1 FROM public.purchase_return_lines return_line
        LEFT JOIN LATERAL(SELECT sum(finance.quantity_base) quantity_base
          FROM public.purchase_return_finance_allocations finance
          WHERE finance.company_id=return_line.company_id
            AND finance.return_line_id=return_line.id) allocated ON TRUE
        WHERE return_line.company_id=return_document.company_id
          AND return_line.document_id=return_document.id
          AND round(COALESCE(allocated.quantity_base,0),6)
            <>round(return_line.return_base_qty,6)));
  SELECT count(*),round(COALESCE(sum(note.supplier_refund_receivable),0),4)
    INTO v_return_rows,v_refund_receivable
  FROM public.supplier_return_credit_notes note
  JOIN public.purchase_return_documents return_document
    ON return_document.company_id=note.company_id
   AND return_document.id=note.purchase_return_id
  WHERE return_document.company_id=p_company_id
    AND return_document.supplier_order_id=p_order_id;
  RETURN jsonb_build_object(
    'supplierOrderId',v_order.id,'orderNo',v_order.order_no,
    'orderStatus',v_order.status,'netReceivedBaseQty',v_net,
    'draftReturnRows',v_draft_returns,'draftBillRows',v_draft_bills,
    'invalidPostedReturnFinanceRows',v_invalid_finance,
    'supplierCreditNoteRows',v_return_rows,
    'supplierRefundReceivable',v_refund_receivable,
    'canCancel',v_order.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
      AND v_net=0 AND v_draft_returns=0 AND v_draft_bills=0 AND v_invalid_finance=0,
    'blockers',to_jsonb(array_remove(ARRAY[
      CASE WHEN v_net<>0 THEN 'SUPPLIER_ORDER_RETURN_REQUIRED_BEFORE_CANCEL' END,
      CASE WHEN v_draft_returns>0 THEN 'SUPPLIER_ORDER_DRAFT_RETURN_REQUIRES_COMPLETION' END,
      CASE WHEN v_draft_bills>0 THEN 'SUPPLIER_ORDER_DRAFT_BILL_REQUIRES_CANCEL' END,
      CASE WHEN v_invalid_finance>0 THEN 'SUPPLIER_ORDER_RETURN_FINANCE_RECONCILIATION_REQUIRED' END
    ],NULL)));
END
$$;

CREATE FUNCTION public.get_purchase_supplier_order_return_readiness(
  p_order_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  RETURN private.purchase_supplier_order_return_readiness_core(v_company,p_order_id);
END
$$;

ALTER FUNCTION public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)
  RENAME TO purchase_return_gate_previous_cancel_supplier_order;
ALTER FUNCTION public.purchase_return_gate_previous_cancel_supplier_order(
  uuid,bigint,uuid,text) SET SCHEMA private;

CREATE FUNCTION public.cancel_purchase_supplier_order(
  p_document_id uuid,p_master_version bigint,p_operation_id uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_status text;
  v_ready jsonb;
BEGIN
  SELECT document.status INTO v_status FROM public.supplier_order_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id;
  IF v_status IS NULL THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;
  -- Preserve exact retry behavior of the previous cancellation runtime.
  IF v_status='CANCELED' THEN
    RETURN private.purchase_return_gate_previous_cancel_supplier_order(
      p_document_id,p_master_version,p_operation_id,p_reason);
  END IF;
  v_ready:=private.purchase_supplier_order_return_readiness_core(v_company,p_document_id);
  IF NOT COALESCE((v_ready->>'canCancel')::boolean,false) THEN
    IF (v_ready->>'netReceivedBaseQty')::numeric<>0 THEN
      RAISE EXCEPTION 'SUPPLIER_ORDER_RETURN_REQUIRED_BEFORE_CANCEL';
    ELSIF (v_ready->>'draftReturnRows')::bigint>0 THEN
      RAISE EXCEPTION 'SUPPLIER_ORDER_DRAFT_RETURN_REQUIRES_COMPLETION';
    ELSIF (v_ready->>'draftBillRows')::bigint>0 THEN
      RAISE EXCEPTION 'SUPPLIER_ORDER_DRAFT_BILL_REQUIRES_CANCEL';
    ELSE
      RAISE EXCEPTION 'SUPPLIER_ORDER_RETURN_FINANCE_RECONCILIATION_REQUIRED';
    END IF;
  END IF;
  RETURN private.purchase_return_gate_previous_cancel_supplier_order(
    p_document_id,p_master_version,p_operation_id,p_reason);
END
$$;

REVOKE ALL ON FUNCTION private.purchase_supplier_order_return_readiness_core(uuid,uuid),
  private.purchase_return_gate_previous_cancel_supplier_order(uuid,bigint,uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.purchase_supplier_order_return_readiness_core(uuid,uuid),
  private.purchase_return_gate_previous_cancel_supplier_order(uuid,bigint,uuid,text)
TO service_role;
REVOKE ALL ON FUNCTION public.get_purchase_supplier_order_return_readiness(uuid),
  public.cancel_purchase_supplier_order(uuid,bigint,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_supplier_order_return_readiness(uuid),
  public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260919142000','backoffice_purchase_return_po_cancellation_gate',
  'Adds explainable PO cancellation readiness and blocks cancellation until net receipt, active Return/Bill, and Backoffice Return Finance dependencies reconcile; open Supplier refund receivable remains valid append-only Finance history');
NOTIFY pgrst,'reload schema';
COMMIT;

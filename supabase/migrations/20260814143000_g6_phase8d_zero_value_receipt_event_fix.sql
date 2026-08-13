-- G6 phase 8D forward fix: a fully rejected/zero-value Goods Receipt has no GL effect.
-- Migration changes runtime only and does not process historical Events.

BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 8D runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814143000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814143000';
  END IF;
END
$guard$;

ALTER FUNCTION private.post_purchase_ap_financial_event_core(
  UUID,UUID,BIGINT,UUID)
RENAME TO post_purchase_ap_positive_financial_event_core;

CREATE FUNCTION private.post_purchase_ap_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%ROWTYPE;
  v_receipt public.goods_receipt_documents%ROWTYPE;
  v_line_total NUMERIC(20,4); v_batch_total NUMERIC(20,4);
  v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT'; END IF;

  IF v_event.status::TEXT='CANCELED'
     AND v_event.system_event_key='GOODS_RECEIPT'
     AND v_event.error_message='NO_FINANCIAL_EFFECT' THEN
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
      'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
      'idempotentReplay',TRUE);
  END IF;

  IF v_event.status::TEXT='HOLD'
     AND v_event.system_event_key='GOODS_RECEIPT' THEN
    IF v_event.event_type::TEXT<>'PURCHASE_POSTED'
       OR v_event.source_table<>'goods_receipt_documents' THEN
      RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
    SELECT * INTO v_receipt FROM public.goods_receipt_documents document
    WHERE document.company_id=p_company_id AND document.id=v_event.source_id
      AND document.status='POSTED' AND document.financial_event_id=v_event.id FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
    SELECT round(COALESCE(sum(line.provisional_ap_amount),0),4)
      INTO v_line_total FROM public.goods_receipt_lines line
    WHERE line.company_id=p_company_id AND line.document_id=v_receipt.id;
    SELECT round(COALESCE(sum(batch.qty_purchased*batch.cogs_unit),0),4)
      INTO v_batch_total FROM public.product_batches batch
    JOIN public.goods_receipt_condition_allocations allocation
      ON allocation.company_id=batch.company_id
     AND allocation.id=batch.goods_receipt_condition_allocation_id
    JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
     AND line.id=allocation.receipt_line_id
    WHERE line.company_id=p_company_id AND line.document_id=v_receipt.id;

    IF round(v_receipt.provisional_ap_total,4)=0
       AND v_line_total=0 AND v_batch_total=0
       AND round((v_event.amounts->>'inventoryDebit')::NUMERIC,4)=0
       AND round((v_event.amounts->>'supplierApProvisionalCredit')::NUMERIC,4)=0 THEN
      UPDATE public.financial_events SET status='CANCELED'::public.event_status,
        processed_at=v_now,error_message='NO_FINANCIAL_EFFECT',
        transaction_rule_version=20260814143000
      WHERE company_id=p_company_id AND id=v_event.id;
      RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',NULL,
        'journalNo',NULL,'status','CANCELED','reason','NO_FINANCIAL_EFFECT',
        'idempotentReplay',FALSE);
    END IF;
  END IF;

  RETURN private.post_purchase_ap_positive_financial_event_core(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

REVOKE ALL ON FUNCTION
  private.post_purchase_ap_positive_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_purchase_ap_financial_event_core(UUID,UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.post_purchase_ap_positive_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_purchase_ap_financial_event_core(UUID,UUID,BIGINT,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260814143000','g6_phase8d_zero_value_receipt_event_fix',
  'Closes fully source-verified zero-value Goods Receipt Events as CANCELED NO_FINANCIAL_EFFECT without a zero Journal; positive Purchase/AP runtime remains unchanged');
COMMIT;

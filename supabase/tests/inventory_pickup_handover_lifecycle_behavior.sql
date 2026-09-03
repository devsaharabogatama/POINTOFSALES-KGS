-- Inventory Pickup direct handover regression.
-- SAFETY: any exercised operational mutation is rolled back.
BEGIN;

DO $test$
DECLARE v_candidate RECORD;v_result JSONB;v_before_version BIGINT;
  v_before_movements BIGINT;v_before_events BIGINT;v_before_allocations BIGINT;
  v_stale_rejected BOOLEAN:=FALSE;v_definition TEXT;
BEGIN
  IF private.sales_delivery_transition_target(
      'READY','PICKUP','DELIVER',NULL)<>'DELIVERED' THEN
    RAISE EXCEPTION 'TEST_FAILED: Pickup transition target invalid';
  END IF;
  BEGIN
    PERFORM private.sales_delivery_transition_target(
      'READY','DELIVERY','DELIVER',NULL);
  EXCEPTION WHEN OTHERS THEN
    v_stale_rejected:=SQLERRM='INVALID_SALES_DELIVERY_TRANSITION';
  END;
  IF NOT v_stale_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Delivery skipped Dispatch';
  END IF;
  SELECT pg_get_constraintdef(constraint_row.oid) INTO v_definition
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.sales_delivery_documents'::regclass
    AND constraint_row.conname='sales_delivery_document_lifecycle_check';
  IF v_definition IS NULL OR v_definition!~'fulfillment_mode.*PICKUP'
    OR v_definition!~'reservation_id IS NULL' THEN
    RAISE EXCEPTION 'TEST_FAILED: Pickup lifecycle constraint not installed';
  END IF;

  SELECT delivery.id delivery_id,delivery.company_id,delivery.sales_id,
    delivery.master_version,membership.user_id actor_id
  INTO v_candidate
  FROM public.sales_delivery_documents delivery
  JOIN public.company_memberships membership
    ON membership.company_id=delivery.company_id
   AND membership.status='ACTIVE'
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  WHERE delivery.fulfillment_mode='PICKUP' AND delivery.reservation_id IS NULL
    AND delivery.status='READY'
  ORDER BY delivery.created_at DESC,membership.user_id LIMIT 1;
  IF v_candidate.delivery_id IS NULL THEN
    RAISE NOTICE 'No eligible legacy Pickup READY row; structural boundary tested.';
    RETURN;
  END IF;

  INSERT INTO public.user_active_company_contexts(
    user_id,company_id,selection_source)
  VALUES(v_candidate.actor_id,v_candidate.company_id,'BACKOFFICE')
  ON CONFLICT(user_id) DO UPDATE SET company_id=EXCLUDED.company_id,
    selection_source=EXCLUDED.selection_source;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_candidate.actor_id,'role','authenticated')::TEXT,TRUE);
  SELECT count(*) INTO v_before_movements FROM public.stock_movements
  WHERE company_id=v_candidate.company_id;
  SELECT count(*) INTO v_before_events FROM public.financial_events
  WHERE company_id=v_candidate.company_id;
  SELECT count(*) INTO v_before_allocations FROM public.sales_dispatch_allocations
  WHERE company_id=v_candidate.company_id;
  v_before_version:=v_candidate.master_version;

  v_result:=private.acp5e_update_sales_delivery_status_odr3_legacy(
    v_candidate.delivery_id,v_before_version,'DELIVER',NULL);
  IF v_result->>'status'<>'DELIVERED'
    OR NOT EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=v_candidate.company_id
        AND delivery.id=v_candidate.delivery_id AND delivery.status='DELIVERED'
        AND delivery.master_version=v_before_version+1
        AND delivery.delivered_at IS NOT NULL
        AND delivery.delivered_by=v_candidate.actor_id
        AND delivery.dispatched_at IS NULL AND delivery.dispatched_by IS NULL
        AND delivery.total_dispatched_base_qty=0)
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=v_candidate.company_id
        AND sale.id=v_candidate.sales_id AND sale.sj_status='SHIPPED')
    OR NOT EXISTS(SELECT 1 FROM public.sales_document_audit audit
      WHERE audit.company_id=v_candidate.company_id
        AND audit.document_id=v_candidate.delivery_id
        AND audit.action='DELIVER' AND audit.actor_id=v_candidate.actor_id) THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy Pickup handover result invalid';
  END IF;
  IF v_before_movements<>(SELECT count(*) FROM public.stock_movements
      WHERE company_id=v_candidate.company_id)
    OR v_before_events<>(SELECT count(*) FROM public.financial_events
      WHERE company_id=v_candidate.company_id)
    OR v_before_allocations<>(SELECT count(*) FROM public.sales_dispatch_allocations
      WHERE company_id=v_candidate.company_id) THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy Pickup handover created final effect';
  END IF;
  v_stale_rejected:=FALSE;
  BEGIN
    PERFORM private.acp5e_update_sales_delivery_status_odr3_legacy(
      v_candidate.delivery_id,v_before_version,'DELIVER',NULL);
  EXCEPTION WHEN OTHERS THEN
    v_stale_rejected:=SQLERRM='MASTER_VERSION_CONFLICT';
  END;
  IF NOT v_stale_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: stale Pickup handover was accepted';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'inventory_pickup_handover_lifecycle_behavior' check_name,'PASS' status,
  jsonb_build_object('rolledBack',TRUE,'tested',ARRAY[
    'Pickup READY direct handover','Delivery cannot skip Dispatch',
    'no Stock Movement Dispatch allocation or Finance effect',
    'optimistic version and audit']) details;

-- Purchase Daily Replenishment Step 6/6B: 23:59 scheduler and canonical cancellation.
BEGIN;

DO $guard$
DECLARE v_operation_check text;v_audit_check text;v_order_guard text;v_batch_guard text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260913120000','20260913130000','20260914100000',
        '20260914110000','20260914111000','20260914112000','20260914130000'))<>7 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase Steps 3-6A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF to_regclass('public.purchase_daily_scheduler_runs') IS NOT NULL
    OR to_regclass('public.purchase_daily_scheduler_attempts') IS NOT NULL
    OR to_regclass('public.purchase_supplier_order_cancel_operations') IS NOT NULL
    OR to_regprocedure('private.run_purchase_daily_replenishment_scheduler(timestamptz)') IS NOT NULL
    OR to_regprocedure('public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text)') IS NOT NULL
    OR to_regprocedure('public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 6B object collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.company_purchase_replenishment_settings setting
      JOIN public.companies company ON company.id=setting.company_id
      WHERE company.status='ACTIVE' AND setting.replenishment_mode<>'MANUAL'
        AND (setting.updated_by IS NULL OR NOT EXISTS(
          SELECT 1 FROM public.profiles profile WHERE profile.id=setting.updated_by))) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: automatic Company requires technical sponsor';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.supplier_order_documents document
    LEFT JOIN LATERAL(
      SELECT COALESCE(sum(line.accepted_good_base_qty+line.damaged_base_qty),0) quantity
      FROM public.goods_receipt_lines line
      JOIN public.goods_receipt_documents receipt
        ON receipt.company_id=line.company_id AND receipt.id=line.document_id
       AND receipt.status='POSTED'
      JOIN public.supplier_order_lines order_line
        ON order_line.company_id=line.company_id
       AND order_line.id=line.supplier_order_line_id
      WHERE order_line.company_id=document.company_id
        AND order_line.document_id=document.id
    ) received ON true
    LEFT JOIN LATERAL(
      SELECT COALESCE(sum(line.return_base_qty),0) quantity
      FROM public.purchase_return_lines line
      JOIN public.purchase_return_documents return_document
        ON return_document.company_id=line.company_id
       AND return_document.id=line.document_id AND return_document.status='POSTED'
      WHERE return_document.company_id=document.company_id
        AND return_document.supplier_order_id=document.id
    ) returned ON true
    WHERE document.status='CANCELED'
      AND received.quantity-returned.quantity<>0
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canceled PO has unreturned posted Receipt';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_available_extensions WHERE name='pg_cron') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: pg_cron unavailable';
  END IF;
  SELECT pg_get_constraintdef(oid) INTO v_operation_check FROM pg_constraint
  WHERE conrelid='public.purchase_daily_batch_operations'::regclass
    AND conname='purchase_daily_batch_operations_operation_type_check';
  SELECT pg_get_constraintdef(oid) INTO v_audit_check FROM pg_constraint
  WHERE conrelid='public.purchase_daily_batch_audit'::regclass
    AND conname='purchase_daily_batch_audit_action_check';
  SELECT pg_get_functiondef(
    'private.trg_g5_guard_supplier_order_history()'::regprocedure) INTO v_order_guard;
  SELECT pg_get_functiondef(
    'private.trg_guard_purchase_daily_batch()'::regprocedure) INTO v_batch_guard;
  IF v_operation_check IS NULL OR position('GENERATE_AUTO_RO' in v_operation_check)=0
    OR position('CONFIRM_AUTO_RO' in v_operation_check)=0
    OR position('GENERATE_AUTO_PO' in v_operation_check)=0
    OR position('CANCEL_BATCH' in v_operation_check)>0
    OR v_audit_check IS NULL OR position('AUTO_PO_GENERATE' in v_audit_check)=0
    OR position('AUTO_PO_REUSE' in v_audit_check)=0
    OR position('CANCEL' in v_audit_check)>0
    OR position('OLD.status IN' in v_order_guard)=0
    OR position('OLD.status IN' in v_batch_guard)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical cancellation guard drift';
  END IF;
END
$guard$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

ALTER TABLE public.purchase_daily_batch_operations
  DROP CONSTRAINT purchase_daily_batch_operations_operation_type_check,
  ADD CONSTRAINT purchase_daily_batch_operations_operation_type_check CHECK(
    operation_type IN('GENERATE_AUTO_RO','CONFIRM_AUTO_RO','GENERATE_AUTO_PO','CANCEL_BATCH'));
ALTER TABLE public.purchase_daily_batch_audit
  DROP CONSTRAINT purchase_daily_batch_audit_action_check,
  ADD CONSTRAINT purchase_daily_batch_audit_action_check CHECK(
    action IN('GENERATE','REUSE','CONFIRM','AUTO_PO_REUSE','AUTO_PO_GENERATE','CANCEL'));

CREATE TABLE public.purchase_daily_scheduler_runs(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  business_date date NOT NULL,
  mode_snapshot text NOT NULL CHECK(mode_snapshot IN('AUTO_RO','AUTO_PO')),
  execution_actor text NOT NULL DEFAULT 'SYSTEM_AUTOMATION'
    CHECK(execution_actor='SYSTEM_AUTOMATION'),
  actor_display_name text NOT NULL DEFAULT 'Sistem Otomatis'
    CHECK(actor_display_name='Sistem Otomatis'),
  technical_sponsor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  status text NOT NULL CHECK(status IN('GENERATED','NO_DEMAND','FAILED')),
  attempt_count integer NOT NULL DEFAULT 1 CHECK(attempt_count>0),
  result_snapshot jsonb,
  error_code text,
  first_attempted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_attempted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_daily_scheduler_company_date_unique
    UNIQUE(company_id,business_date),
  CONSTRAINT purchase_daily_scheduler_result_shape CHECK(
    (status IN('GENERATED','NO_DEMAND') AND result_snapshot IS NOT NULL AND error_code IS NULL)
    OR (status='FAILED' AND error_code IS NOT NULL))
);

CREATE TABLE public.purchase_daily_scheduler_attempts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  business_date date NOT NULL,
  effective_at timestamptz NOT NULL,
  mode_snapshot text NOT NULL CHECK(mode_snapshot IN('AUTO_RO','AUTO_PO')),
  execution_actor text NOT NULL DEFAULT 'SYSTEM_AUTOMATION'
    CHECK(execution_actor='SYSTEM_AUTOMATION'),
  actor_display_name text NOT NULL DEFAULT 'Sistem Otomatis'
    CHECK(actor_display_name='Sistem Otomatis'),
  technical_sponsor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  status text NOT NULL CHECK(status IN('GENERATED','NO_DEMAND','REUSED','FAILED')),
  result_snapshot jsonb,
  error_code text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_daily_scheduler_attempt_result_shape CHECK(
    (status IN('GENERATED','NO_DEMAND','REUSED')
      AND result_snapshot IS NOT NULL AND error_code IS NULL)
    OR (status='FAILED' AND error_code IS NOT NULL))
);
CREATE INDEX purchase_daily_scheduler_attempt_company_date_idx
  ON public.purchase_daily_scheduler_attempts(company_id,business_date,created_at);

CREATE TABLE public.purchase_supplier_order_cancel_operations(
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL,
  supplier_order_id uuid NOT NULL,
  expected_master_version bigint NOT NULL,
  request_hash text NOT NULL CHECK(btrim(request_hash)<>''),
  reason text,
  result_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_supplier_order_cancel_ops_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT purchase_supplier_order_cancel_ops_order_fk
    FOREIGN KEY(company_id,supplier_order_id)
    REFERENCES public.supplier_order_documents(company_id,id) ON DELETE RESTRICT
);
CREATE INDEX purchase_supplier_order_cancel_ops_order_idx
  ON public.purchase_supplier_order_cancel_operations(company_id,supplier_order_id,created_at);

CREATE FUNCTION private.trg_guard_purchase_scheduler_cancel_history()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'PURCHASE_AUTOMATION_HISTORY_IMMUTABLE'; END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER guard_purchase_supplier_order_cancel_operations
BEFORE UPDATE OR DELETE ON public.purchase_supplier_order_cancel_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_scheduler_cancel_history();
CREATE TRIGGER guard_purchase_daily_scheduler_attempts
BEFORE UPDATE OR DELETE ON public.purchase_daily_scheduler_attempts
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_scheduler_cancel_history();

CREATE FUNCTION private.purchase_supplier_order_net_received_base_qty(
  p_company_id uuid,p_supplier_order_id uuid
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  WITH received AS (
    SELECT COALESCE(sum(line.accepted_good_base_qty+line.damaged_base_qty),0) quantity
    FROM public.goods_receipt_lines line
    JOIN public.goods_receipt_documents receipt
      ON receipt.company_id=line.company_id AND receipt.id=line.document_id
     AND receipt.status='POSTED'
    JOIN public.supplier_order_lines order_line
      ON order_line.company_id=line.company_id AND order_line.id=line.supplier_order_line_id
    WHERE line.company_id=p_company_id AND order_line.document_id=p_supplier_order_id
  ), returned AS (
    SELECT COALESCE(sum(line.return_base_qty),0) quantity
    FROM public.purchase_return_lines line
    JOIN public.purchase_return_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
     AND document.status='POSTED'
    WHERE line.company_id=p_company_id AND document.supplier_order_id=p_supplier_order_id
  )
  SELECT received.quantity-returned.quantity FROM received,returned
$$;

CREATE OR REPLACE FUNCTION private.trg_g5_guard_supplier_order_history()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'SUPPLIER_ORDER_DELETE_FORBIDDEN'; END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id
    OR NEW.id IS DISTINCT FROM OLD.id
    OR NEW.order_no IS DISTINCT FROM OLD.order_no
    OR NEW.ordered_by IS DISTINCT FROM OLD.ordered_by
    OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_IDENTITY_IMMUTABLE';
  END IF;
  IF OLD.status='CANCELED'
    OR (OLD.status='RECEIVED' AND NOT (NEW.status='CANCELED'
      AND private.purchase_supplier_order_net_received_base_qty(
        OLD.company_id,OLD.id)=0)) THEN
    RAISE EXCEPTION 'FINAL_SUPPLIER_ORDER_IMMUTABLE';
  END IF;
  IF NOT (NEW.status=OLD.status
    OR (OLD.status='DRAFT' AND NEW.status IN('CONFIRMED','CANCELED'))
    OR (OLD.status='CONFIRMED' AND NEW.status IN('PARTIALLY_RECEIVED','RECEIVED','CANCELED'))
    OR (OLD.status='PARTIALLY_RECEIVED' AND NEW.status IN('RECEIVED','CANCELED'))
    OR (OLD.status='RECEIVED' AND NEW.status='CANCELED'
      AND private.purchase_supplier_order_net_received_base_qty(
        OLD.company_id,OLD.id)=0)) THEN
    RAISE EXCEPTION 'INVALID_SUPPLIER_ORDER_STATUS_TRANSITION';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION private.trg_guard_purchase_daily_batch()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_DELETE_FORBIDDEN'; END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id OR NEW.id IS DISTINCT FROM OLD.id
    OR NEW.batch_no IS DISTINCT FROM OLD.batch_no
    OR NEW.business_date IS DISTINCT FROM OLD.business_date
    OR NEW.mode_snapshot IS DISTINCT FROM OLD.mode_snapshot
    OR NEW.cutoff_at IS DISTINCT FROM OLD.cutoff_at
    OR NEW.generated_by IS DISTINCT FROM OLD.generated_by
    OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_IDENTITY_IMMUTABLE';
  END IF;
  IF NOT (NEW.status=OLD.status
    OR (OLD.status='DRAFT' AND NEW.status IN('READY','CANCELED'))
    OR (OLD.status='READY' AND NEW.status IN('PARTIALLY_RECEIVED','RECEIVED','CANCELED'))
    OR (OLD.status='PARTIALLY_RECEIVED' AND NEW.status IN('RECEIVED','CANCELED'))
    OR (OLD.status='RECEIVED' AND NEW.status='CANCELED'
      AND NOT EXISTS(SELECT 1 FROM public.supplier_order_documents document
        WHERE document.company_id=OLD.company_id AND document.purchase_daily_batch_id=OLD.id
          AND document.status<>'CANCELED'))) THEN
    RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_STATUS_TRANSITION_INVALID';
  END IF;
  IF OLD.status='CANCELED' OR (OLD.status='RECEIVED' AND NEW.status<>'CANCELED') THEN
    RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_FINAL_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.cancel_purchase_daily_batch_core(
  p_company_id uuid,p_batch_id uuid,p_expected_master_version bigint,
  p_operation_id uuid,p_actor_id uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_batch public.purchase_daily_batches%rowtype;v_existing record;
  v_hash text;v_before jsonb;v_after jsonb;v_result jsonb;
BEGIN
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'PURCHASE_CANCEL_OPERATION:'||p_operation_id::text,0));
  v_hash:=md5(jsonb_build_object('batchId',p_batch_id,'expectedVersion',
    p_expected_master_version,'reason',NULLIF(btrim(COALESCE(p_reason,'')),''))::text);
  SELECT * INTO v_existing FROM public.purchase_daily_batch_operations operation
  WHERE operation.company_id=p_company_id AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.operation_type<>'CANCEL_BATCH' OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT'; END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_daily_batch_operations operation
      WHERE operation.id=p_operation_id) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':PURCHASE_DAILY_REPLENISHMENT',0));
  SELECT * INTO v_batch FROM public.purchase_daily_batches batch
  WHERE batch.company_id=p_company_id AND batch.id=p_batch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_NOT_FOUND'; END IF;
  IF v_batch.mode_snapshot<>'AUTO_RO' OR v_batch.status<>'DRAFT' THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_DRAFT_REQUIRED'; END IF;
  IF p_expected_master_version IS NULL
    OR v_batch.master_version<>p_expected_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF EXISTS(SELECT 1 FROM public.supplier_order_documents document
      WHERE document.company_id=p_company_id AND document.purchase_daily_batch_id=p_batch_id
        AND document.status<>'CANCELED') THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_HAS_ACTIVE_PO'; END IF;
  v_before:=private.purchase_daily_batch_snapshot(p_company_id,p_batch_id);
  v_result:=jsonb_build_object('batchId',p_batch_id,'batchNo',v_batch.batch_no,
    'status','CANCELED','masterVersion',v_batch.master_version+1,'exactRetry',false);
  INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,operation_type,
    request_hash,result_snapshot,actor_id)
  VALUES(p_operation_id,p_company_id,p_batch_id,'CANCEL_BATCH',v_hash,v_result,p_actor_id);
  UPDATE public.purchase_daily_batches SET status='CANCELED',master_version=master_version+1,
    updated_at=clock_timestamp() WHERE company_id=p_company_id AND id=p_batch_id;
  v_after:=private.purchase_daily_batch_snapshot(p_company_id,p_batch_id);
  INSERT INTO public.purchase_daily_batch_audit(company_id,batch_id,operation_id,action,
    actor_id,before_state,after_state)
  VALUES(p_company_id,p_batch_id,p_operation_id,'CANCEL',p_actor_id,v_before,v_after);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.cancel_purchase_daily_auto_ro(
  p_batch_id uuid,p_master_version bigint,p_operation_id uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','CANCEL_FINAL');
  RETURN private.cancel_purchase_daily_batch_core(v_company,p_batch_id,p_master_version,
    p_operation_id,v_actor,p_reason);
END
$$;

CREATE FUNCTION private.cancel_purchase_supplier_order_core(
  p_company_id uuid,p_document_id uuid,p_expected_master_version bigint,
  p_operation_id uuid,p_actor_id uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_document public.supplier_order_documents%rowtype;v_existing record;
  v_hash text;v_before jsonb;v_after jsonb;v_result jsonb;v_request uuid;
  v_receipt record;v_batch public.purchase_daily_batches%rowtype;v_batch_before jsonb;
  v_batch_after jsonb;v_batch_result jsonb;
BEGIN
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'PURCHASE_CANCEL_OPERATION:'||p_operation_id::text,0));
  v_hash:=md5(jsonb_build_object('documentId',p_document_id,'expectedVersion',
    p_expected_master_version,'reason',NULLIF(btrim(COALESCE(p_reason,'')),''))::text);
  SELECT * INTO v_existing FROM public.purchase_supplier_order_cancel_operations operation
  WHERE operation.company_id=p_company_id AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.supplier_order_id<>p_document_id OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT'; END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_supplier_order_cancel_operations operation
      WHERE operation.id=p_operation_id)
    OR EXISTS(SELECT 1 FROM public.purchase_daily_batch_operations operation
      WHERE operation.id=p_operation_id) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':SUPPLIER_ORDER_CANCEL:'||p_document_id::text,0));
  SELECT * INTO v_document FROM public.supplier_order_documents document
  WHERE document.company_id=p_company_id AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_FOUND'; END IF;
  IF v_document.status NOT IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED') THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_NOT_CANCELABLE'; END IF;
  IF p_expected_master_version IS NULL
    OR v_document.master_version<>p_expected_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF private.purchase_supplier_order_net_received_base_qty(p_company_id,p_document_id)<>0 THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_RETURN_REQUIRED_BEFORE_CANCEL'; END IF;
  v_before:=to_jsonb(v_document);
  FOR v_receipt IN SELECT receipt.* FROM public.goods_receipt_documents receipt
    WHERE receipt.company_id=p_company_id AND receipt.supplier_order_id=p_document_id
      AND receipt.status='DRAFT' FOR UPDATE
  LOOP
    UPDATE public.goods_receipt_documents SET status='CANCELED',canceled_by=p_actor_id,
      canceled_at=clock_timestamp(),master_version=master_version+1,
      updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_receipt.id;
    INSERT INTO public.goods_receipt_audit(company_id,document_id,action,actor_id,
      before_state,after_state)
    SELECT p_company_id,v_receipt.id,'CANCEL',p_actor_id,to_jsonb(v_receipt),to_jsonb(receipt)
    FROM public.goods_receipt_documents receipt
    WHERE receipt.company_id=p_company_id AND receipt.id=v_receipt.id;
  END LOOP;
  UPDATE public.supplier_order_documents SET status='CANCELED',
    cancellation_reason=NULLIF(btrim(COALESCE(p_reason,'')),''),canceled_by=p_actor_id,
    canceled_at=clock_timestamp(),master_version=master_version+1,
    updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND id=p_document_id;
  SELECT to_jsonb(document) INTO v_after FROM public.supplier_order_documents document
  WHERE document.company_id=p_company_id AND document.id=p_document_id;
  INSERT INTO public.supplier_order_audit(company_id,document_id,action,actor_id,
    before_state,after_state)
  VALUES(p_company_id,p_document_id,'CANCEL',p_actor_id,v_before,v_after);
  IF v_document.order_source='MANUAL' THEN
    FOR v_request IN SELECT DISTINCT request_line.document_id
      FROM public.supplier_order_request_allocations allocation
      JOIN public.supplier_order_lines order_line
        ON order_line.company_id=allocation.company_id
       AND order_line.id=allocation.supplier_order_line_id
      JOIN public.stock_request_lines request_line
        ON request_line.company_id=allocation.company_id
       AND request_line.id=allocation.stock_request_line_id
      WHERE order_line.company_id=p_company_id AND order_line.document_id=p_document_id
    LOOP
      PERFORM private.g5_refresh_stock_request_order_status(p_company_id,v_request,p_actor_id);
    END LOOP;
  END IF;
  v_result:=jsonb_build_object('documentId',p_document_id,'orderNo',v_document.order_no,
    'status','CANCELED','masterVersion',v_document.master_version+1,
    'netReceivedBaseQty',0,'exactRetry',false);
  INSERT INTO public.purchase_supplier_order_cancel_operations(id,company_id,
    supplier_order_id,expected_master_version,request_hash,reason,result_snapshot,actor_id)
  VALUES(p_operation_id,p_company_id,p_document_id,p_expected_master_version,v_hash,
    NULLIF(btrim(COALESCE(p_reason,'')),''),v_result,p_actor_id);

  IF v_document.purchase_daily_batch_id IS NOT NULL
    AND NOT EXISTS(SELECT 1 FROM public.supplier_order_documents document
      WHERE document.company_id=p_company_id
        AND document.purchase_daily_batch_id=v_document.purchase_daily_batch_id
        AND document.status<>'CANCELED') THEN
    SELECT * INTO v_batch FROM public.purchase_daily_batches batch
    WHERE batch.company_id=p_company_id AND batch.id=v_document.purchase_daily_batch_id FOR UPDATE;
    IF FOUND AND v_batch.status<>'CANCELED' THEN
      v_batch_before:=private.purchase_daily_batch_snapshot(p_company_id,v_batch.id);
      v_batch_result:=jsonb_build_object('batchId',v_batch.id,'batchNo',v_batch.batch_no,
        'status','CANCELED','masterVersion',v_batch.master_version+1,'exactRetry',false);
      INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,operation_type,
        request_hash,result_snapshot,actor_id)
      VALUES(p_operation_id,p_company_id,v_batch.id,'CANCEL_BATCH',v_hash,v_batch_result,p_actor_id);
      UPDATE public.purchase_daily_batches SET status='CANCELED',
        master_version=master_version+1,updated_at=clock_timestamp()
      WHERE company_id=p_company_id AND id=v_batch.id;
      v_batch_after:=private.purchase_daily_batch_snapshot(p_company_id,v_batch.id);
      INSERT INTO public.purchase_daily_batch_audit(company_id,batch_id,operation_id,action,
        actor_id,before_state,after_state)
      VALUES(p_company_id,v_batch.id,p_operation_id,'CANCEL',p_actor_id,
        v_batch_before,v_batch_after);
    END IF;
  END IF;
  RETURN v_result;
END
$$;

CREATE FUNCTION public.cancel_purchase_supplier_order(
  p_document_id uuid,p_master_version bigint,p_operation_id uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','CANCEL_FINAL');
  RETURN private.cancel_purchase_supplier_order_core(v_company,p_document_id,
    p_master_version,p_operation_id,v_actor,p_reason);
END
$$;

CREATE FUNCTION private.run_purchase_daily_replenishment_scheduler(
  p_effective_at timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_row record;v_prior public.purchase_daily_scheduler_runs%rowtype;
  v_date date;v_operation uuid;v_result jsonb;
  v_status text;v_generated integer:=0;v_no_demand integer:=0;v_failed integer:=0;
  v_error text;
BEGIN
  FOR v_row IN SELECT setting.*,company.timezone
    FROM public.company_purchase_replenishment_settings setting
    JOIN public.companies company ON company.id=setting.company_id AND company.status='ACTIVE'
    WHERE setting.replenishment_mode IN('AUTO_RO','AUTO_PO')
      AND setting.updated_by IS NOT NULL
      AND (p_effective_at AT TIME ZONE company.timezone)::time>=setting.cutoff_local_time
      AND (p_effective_at AT TIME ZONE company.timezone)::time
        <setting.cutoff_local_time+interval '1 minute'
    ORDER BY setting.company_id
  LOOP
    v_date:=(p_effective_at AT TIME ZONE v_row.timezone)::date;
    SELECT * INTO v_prior FROM public.purchase_daily_scheduler_runs run
    WHERE run.company_id=v_row.company_id AND run.business_date=v_date FOR UPDATE;
    IF FOUND AND v_prior.status IN('GENERATED','NO_DEMAND') THEN
      UPDATE public.purchase_daily_scheduler_runs SET attempt_count=attempt_count+1,
        last_attempted_at=clock_timestamp()
      WHERE company_id=v_row.company_id AND business_date=v_date;
      INSERT INTO public.purchase_daily_scheduler_attempts(company_id,business_date,
        effective_at,mode_snapshot,technical_sponsor_id,operation_id,status,result_snapshot)
      VALUES(v_row.company_id,v_date,p_effective_at,v_prior.mode_snapshot,
        v_prior.technical_sponsor_id,v_prior.operation_id,'REUSED',v_prior.result_snapshot);
      IF v_prior.status='NO_DEMAND' THEN v_no_demand:=v_no_demand+1;
      ELSE v_generated:=v_generated+1; END IF;
      CONTINUE;
    END IF;
    v_operation:=md5('PURCHASE_DAILY_SCHEDULER|'||v_row.company_id||'|'||v_date||'|'||
      v_row.replenishment_mode)::uuid;
    BEGIN
      IF v_row.replenishment_mode='AUTO_RO' THEN
        v_result:=private.generate_purchase_daily_auto_ro_core(v_row.company_id,v_date,
          v_row.updated_by,v_operation,p_effective_at);
      ELSE
        v_result:=private.generate_purchase_daily_auto_po_core(v_row.company_id,v_date,
          v_row.updated_by,v_operation,p_effective_at);
      END IF;
      v_status:=CASE WHEN COALESCE((v_result->>'noDemand')::boolean,false)
        THEN 'NO_DEMAND' ELSE 'GENERATED' END;
      INSERT INTO public.purchase_daily_scheduler_runs(company_id,business_date,
        mode_snapshot,technical_sponsor_id,operation_id,status,result_snapshot)
      VALUES(v_row.company_id,v_date,v_row.replenishment_mode,v_row.updated_by,
        v_operation,v_status,v_result)
      ON CONFLICT(company_id,business_date) DO UPDATE SET
        attempt_count=purchase_daily_scheduler_runs.attempt_count+1,
        mode_snapshot=excluded.mode_snapshot,
        technical_sponsor_id=excluded.technical_sponsor_id,
        operation_id=excluded.operation_id,
        status=excluded.status,result_snapshot=excluded.result_snapshot,error_code=NULL,
        last_attempted_at=clock_timestamp();
      INSERT INTO public.purchase_daily_scheduler_attempts(company_id,business_date,
        effective_at,mode_snapshot,technical_sponsor_id,operation_id,status,result_snapshot)
      VALUES(v_row.company_id,v_date,p_effective_at,v_row.replenishment_mode,
        v_row.updated_by,v_operation,v_status,v_result);
      IF v_status='NO_DEMAND' THEN v_no_demand:=v_no_demand+1;
      ELSE v_generated:=v_generated+1; END IF;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
      INSERT INTO public.purchase_daily_scheduler_runs(company_id,business_date,
        mode_snapshot,technical_sponsor_id,operation_id,status,error_code)
      VALUES(v_row.company_id,v_date,v_row.replenishment_mode,v_row.updated_by,
        v_operation,'FAILED',left(v_error,500))
      ON CONFLICT(company_id,business_date) DO UPDATE SET
        attempt_count=purchase_daily_scheduler_runs.attempt_count+1,
        mode_snapshot=excluded.mode_snapshot,
        technical_sponsor_id=excluded.technical_sponsor_id,
        operation_id=excluded.operation_id,status='FAILED',
        result_snapshot=NULL,error_code=excluded.error_code,
        last_attempted_at=clock_timestamp();
      INSERT INTO public.purchase_daily_scheduler_attempts(company_id,business_date,
        effective_at,mode_snapshot,technical_sponsor_id,operation_id,status,error_code)
      VALUES(v_row.company_id,v_date,p_effective_at,v_row.replenishment_mode,
        v_row.updated_by,v_operation,'FAILED',left(v_error,500));
      v_failed:=v_failed+1;
    END;
  END LOOP;
  RETURN jsonb_build_object('executionActor','SYSTEM_AUTOMATION',
    'actorDisplayName','Sistem Otomatis','generatedCompanies',v_generated,
    'noDemandCompanies',v_no_demand,'failedCompanies',v_failed,
    'effectiveAt',p_effective_at);
END
$$;

DO $schedule$
DECLARE v_job bigint;
BEGIN
  SELECT jobid INTO v_job FROM cron.job WHERE jobname='kgs-purchase-daily-replenishment';
  IF v_job IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: scheduler job collision';
  END IF;
  PERFORM cron.schedule('kgs-purchase-daily-replenishment','* * * * *',
    'SELECT private.run_purchase_daily_replenishment_scheduler(clock_timestamp());');
END
$schedule$;

ALTER TABLE public.purchase_daily_scheduler_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_daily_scheduler_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_supplier_order_cancel_operations ENABLE ROW LEVEL SECURITY;
CREATE POLICY purchase_daily_scheduler_runs_read ON public.purchase_daily_scheduler_runs
  FOR SELECT TO authenticated USING(public.private_request_company_matches(company_id));
CREATE POLICY purchase_daily_scheduler_attempts_read ON public.purchase_daily_scheduler_attempts
  FOR SELECT TO authenticated USING(public.private_request_company_matches(company_id));
CREATE POLICY purchase_supplier_order_cancel_ops_read
  ON public.purchase_supplier_order_cancel_operations FOR SELECT TO authenticated
  USING(public.private_request_company_matches(company_id));
REVOKE ALL ON TABLE public.purchase_daily_scheduler_runs,
  public.purchase_daily_scheduler_attempts,
  public.purchase_supplier_order_cancel_operations FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.purchase_daily_scheduler_runs,
  public.purchase_daily_scheduler_attempts,
  public.purchase_supplier_order_cancel_operations TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.purchase_daily_scheduler_runs,
  public.purchase_daily_scheduler_attempts,
  public.purchase_supplier_order_cancel_operations TO service_role;
REVOKE ALL ON FUNCTION private.trg_guard_purchase_scheduler_cancel_history(),
  private.purchase_supplier_order_net_received_base_qty(uuid,uuid),
  private.cancel_purchase_daily_batch_core(uuid,uuid,bigint,uuid,uuid,text),
  private.cancel_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,text),
  private.run_purchase_daily_replenishment_scheduler(timestamptz)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_purchase_scheduler_cancel_history(),
  private.purchase_supplier_order_net_received_base_qty(uuid,uuid),
  private.cancel_purchase_daily_batch_core(uuid,uuid,bigint,uuid,uuid,text),
  private.cancel_purchase_supplier_order_core(uuid,uuid,bigint,uuid,uuid,text),
  private.run_purchase_daily_replenishment_scheduler(timestamptz)
TO service_role;
REVOKE ALL ON FUNCTION public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text),
  public.cancel_purchase_supplier_order(uuid,bigint,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.cancel_purchase_daily_auto_ro(uuid,bigint,uuid,text),
  public.cancel_purchase_supplier_order(uuid,bigint,uuid,text)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914140000','purchase_daily_scheduler_cancellation_runtime',
  'Step 6/6B runs AUTO_RO/AUTO_PO at Company-local 23:59 as Sistem Otomatis with append-only attempts; Draft RO and exact-zero-net-received PO cancellation are audited and idempotent while posted Stock remains reversible only through Purchase Return');
NOTIFY pgrst,'reload schema';
COMMIT;

-- Purchase Daily Replenishment Step 3/6.
-- Activates the atomic AUTO_RO daily generator and RO -> Supplier Order
-- confirmation. The daily batch is the Company-level RO; it does not create a
-- fake Store, POS terminal, or Cashier Session. Receipt/Stock/FIFO/AP remain
-- outside this gate.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260913110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase replenishment Step 2 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260913120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260913120000';
  END IF;
  IF to_regprocedure('private.purchase_uncovered_negative_qty(numeric,numeric)') IS NULL
    OR to_regprocedure('private.get_purchase_daily_replenishment_candidates_core(uuid,date)') IS NULL
    OR to_regprocedure('public.private_active_company_id()') IS NULL
    OR to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL
    OR to_regclass('private.supplier_order_document_no_seq') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Purchase runtime dependency drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
      WHERE status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open Sales process cutover plan';
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_daily_batches)
    OR EXISTS(SELECT 1 FROM public.purchase_daily_batch_lines) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected pre-runtime daily batch rows';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND (
      (table_name='purchase_daily_batches' AND column_name IN(
        'generation_operation_id','confirmed_by','confirmed_at','confirmation_operation_id'))
      OR (table_name='purchase_daily_batch_lines' AND column_name IN('readiness_status','master_version'))
      OR (table_name='supplier_order_documents' AND column_name IN(
        'order_source','document_scope','purchase_daily_batch_id','supplier_assignment_status')))) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 3 column collision';
  END IF;
  IF to_regclass('public.purchase_daily_batch_operations') IS NOT NULL
    OR to_regclass('public.purchase_daily_batch_audit') IS NOT NULL
    OR to_regclass('public.purchase_daily_batch_order_allocations') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 3 relation collision';
  END IF;
  IF to_regprocedure('private.purchase_daily_batch_snapshot(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('private.get_purchase_daily_auto_ro_candidates_core(uuid,date)') IS NOT NULL
    OR to_regprocedure('private.generate_purchase_daily_auto_ro_core(uuid,date,uuid,uuid,timestamptz)') IS NOT NULL
    OR to_regprocedure('private.confirm_purchase_daily_auto_ro_core(uuid,uuid,bigint,uuid,uuid,jsonb,timestamptz)') IS NOT NULL
    OR to_regprocedure('public.generate_purchase_daily_auto_ro(date,uuid)') IS NOT NULL
    OR to_regprocedure('public.confirm_purchase_daily_auto_ro(uuid,bigint,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('public.get_purchase_daily_auto_ro_workspace()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 3 routine collision';
  END IF;
END
$guard$;

CREATE TABLE public.purchase_daily_batch_operations(
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  batch_id uuid,
  operation_type text NOT NULL CHECK(operation_type IN('GENERATE_AUTO_RO','CONFIRM_AUTO_RO')),
  request_hash text NOT NULL CHECK(btrim(request_hash)<>''),
  result_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_daily_batch_operations_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT purchase_daily_batch_operations_batch_fk FOREIGN KEY(company_id,batch_id)
    REFERENCES public.purchase_daily_batches(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.purchase_daily_batch_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL,
  batch_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  action text NOT NULL CHECK(action IN('GENERATE','REUSE','CONFIRM')),
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state jsonb,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_daily_batch_audit_batch_fk FOREIGN KEY(company_id,batch_id)
    REFERENCES public.purchase_daily_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_batch_audit_operation_fk FOREIGN KEY(company_id,operation_id)
    REFERENCES public.purchase_daily_batch_operations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_batch_audit_operation_unique UNIQUE(company_id,operation_id)
);

CREATE TABLE public.purchase_daily_batch_order_allocations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  batch_id uuid NOT NULL,
  batch_line_id uuid NOT NULL,
  supplier_order_id uuid NOT NULL,
  supplier_order_line_id uuid NOT NULL,
  allocated_base_qty numeric(24,6) NOT NULL CHECK(allocated_base_qty>0),
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_daily_order_alloc_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT purchase_daily_order_alloc_batch_fk FOREIGN KEY(company_id,batch_id)
    REFERENCES public.purchase_daily_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_order_alloc_batch_line_fk FOREIGN KEY(company_id,batch_line_id)
    REFERENCES public.purchase_daily_batch_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_order_alloc_order_fk FOREIGN KEY(company_id,supplier_order_id)
    REFERENCES public.supplier_order_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_order_alloc_order_line_fk FOREIGN KEY(company_id,supplier_order_line_id)
    REFERENCES public.supplier_order_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_order_alloc_line_unique UNIQUE(company_id,batch_line_id,supplier_order_line_id)
);

ALTER TABLE public.purchase_daily_batches
  ADD COLUMN generation_operation_id uuid,
  ADD COLUMN confirmed_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD COLUMN confirmed_at timestamptz,
  ADD COLUMN confirmation_operation_id uuid,
  ADD CONSTRAINT purchase_daily_batches_generation_operation_fk
    FOREIGN KEY(company_id,generation_operation_id)
    REFERENCES public.purchase_daily_batch_operations(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT purchase_daily_batches_confirmation_operation_fk
    FOREIGN KEY(company_id,confirmation_operation_id)
    REFERENCES public.purchase_daily_batch_operations(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT purchase_daily_batches_confirmation_shape_check CHECK(
    (status='DRAFT' AND confirmed_by IS NULL AND confirmed_at IS NULL
      AND confirmation_operation_id IS NULL)
    OR status='CANCELED'
    OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL
      AND confirmation_operation_id IS NOT NULL));

ALTER TABLE public.purchase_daily_batch_lines
  ADD COLUMN readiness_status text NOT NULL DEFAULT 'READY',
  ADD COLUMN master_version bigint NOT NULL DEFAULT 1,
  ADD CONSTRAINT purchase_daily_batch_line_readiness_check CHECK(readiness_status IN(
    'READY','SUPPLIER_PENDING','WAREHOUSE_SETUP_REQUIRED',
    'OPEN_REQUEST_WAREHOUSE_AMBIGUOUS','PRODUCT_INACTIVE',
    'SOURCE_WAREHOUSE_INACTIVE','ORDERED')),
  ADD CONSTRAINT purchase_daily_batch_line_version_check CHECK(master_version>0);

ALTER TABLE public.supplier_order_documents
  ADD COLUMN order_source text NOT NULL DEFAULT 'MANUAL',
  ADD COLUMN document_scope text NOT NULL DEFAULT 'STORE',
  ADD COLUMN purchase_daily_batch_id uuid,
  ADD COLUMN supplier_assignment_status text NOT NULL DEFAULT 'ASSIGNED',
  ALTER COLUMN store_id DROP NOT NULL,
  ALTER COLUMN destination_warehouse_id DROP NOT NULL,
  ALTER COLUMN supplier_id DROP NOT NULL,
  ADD CONSTRAINT supplier_order_daily_batch_fk FOREIGN KEY(company_id,purchase_daily_batch_id)
    REFERENCES public.purchase_daily_batches(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT supplier_order_source_check CHECK(order_source IN('MANUAL','DAILY_REPLENISHMENT')),
  ADD CONSTRAINT supplier_order_document_scope_check CHECK(document_scope IN('STORE','COMPANY_MULTI_WAREHOUSE')),
  ADD CONSTRAINT supplier_order_supplier_assignment_check CHECK(
    supplier_assignment_status IN('ASSIGNED','SUPPLIER_PENDING')),
  ADD CONSTRAINT supplier_order_source_shape_check CHECK(
    (order_source='MANUAL' AND document_scope='STORE' AND purchase_daily_batch_id IS NULL
      AND store_id IS NOT NULL AND destination_warehouse_id IS NOT NULL
      AND supplier_id IS NOT NULL AND supplier_assignment_status='ASSIGNED')
    OR (order_source='DAILY_REPLENISHMENT' AND document_scope='COMPANY_MULTI_WAREHOUSE'
      AND purchase_daily_batch_id IS NOT NULL AND store_id IS NULL
      AND destination_warehouse_id IS NULL
      AND ((supplier_id IS NOT NULL AND supplier_assignment_status='ASSIGNED')
        OR (supplier_id IS NULL AND supplier_assignment_status='SUPPLIER_PENDING'))));

CREATE UNIQUE INDEX supplier_order_daily_assigned_group_unique
  ON public.supplier_order_documents(company_id,purchase_daily_batch_id,supplier_id)
  WHERE order_source='DAILY_REPLENISHMENT' AND supplier_id IS NOT NULL;
CREATE UNIQUE INDEX supplier_order_daily_pending_group_unique
  ON public.supplier_order_documents(company_id,purchase_daily_batch_id)
  WHERE order_source='DAILY_REPLENISHMENT' AND supplier_id IS NULL;

CREATE INDEX purchase_daily_batch_operations_batch_idx
  ON public.purchase_daily_batch_operations(company_id,batch_id,created_at);
CREATE INDEX purchase_daily_batch_audit_batch_idx
  ON public.purchase_daily_batch_audit(company_id,batch_id,created_at);
CREATE INDEX purchase_daily_order_alloc_batch_idx
  ON public.purchase_daily_batch_order_allocations(company_id,batch_id,batch_line_id);

COMMENT ON TABLE public.purchase_daily_batches IS
  'Company-level daily Purchase Request (RO) for automatic negative-On-Hand replenishment.';
COMMENT ON COLUMN public.supplier_order_documents.destination_warehouse_id IS
  'Legacy/manual single destination. NULL only for daily multi-Warehouse PO; its lines are authoritative.';
COMMENT ON COLUMN public.supplier_order_documents.store_id IS
  'Legacy/manual Store scope. NULL only for Company-level daily replenishment PO.';

CREATE FUNCTION private.trg_guard_purchase_daily_runtime_history()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'PURCHASE_DAILY_RUNTIME_HISTORY_IMMUTABLE';
END
$$;

CREATE FUNCTION private.trg_guard_purchase_daily_batch()
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
    OR (OLD.status='PARTIALLY_RECEIVED' AND NEW.status IN('RECEIVED','CANCELED'))) THEN
    RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_STATUS_TRANSITION_INVALID';
  END IF;
  IF OLD.status IN('RECEIVED','CANCELED') THEN
    RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_FINAL_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.trg_guard_purchase_daily_batch_line()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_status text;
BEGIN
  SELECT batch.status INTO v_status FROM public.purchase_daily_batches batch
  WHERE batch.company_id=CASE WHEN TG_OP='DELETE' THEN OLD.company_id ELSE NEW.company_id END
    AND batch.id=CASE WHEN TG_OP='DELETE' THEN OLD.batch_id ELSE NEW.batch_id END;
  IF v_status IS NULL THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_NOT_FOUND'; END IF;
  IF TG_OP='INSERT' THEN
    IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_LINES_IMMUTABLE'; END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_LINE_DELETE_FORBIDDEN'; END IF;
  IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_LINES_IMMUTABLE'; END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id OR NEW.id IS DISTINCT FROM OLD.id
    OR NEW.batch_id IS DISTINCT FROM OLD.batch_id OR NEW.line_no IS DISTINCT FROM OLD.line_no
    OR NEW.product_id IS DISTINCT FROM OLD.product_id
    OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
    OR NEW.base_uom_id IS DISTINCT FROM OLD.base_uom_id
    OR NEW.on_hand_snapshot IS DISTINCT FROM OLD.on_hand_snapshot
    OR NEW.open_purchase_base_qty_snapshot IS DISTINCT FROM OLD.open_purchase_base_qty_snapshot
    OR NEW.suggested_product_supplier_id IS DISTINCT FROM OLD.suggested_product_supplier_id
    OR NEW.suggested_supplier_id IS DISTINCT FROM OLD.suggested_supplier_id
    OR NEW.product_sku_snapshot IS DISTINCT FROM OLD.product_sku_snapshot
    OR NEW.product_name_snapshot IS DISTINCT FROM OLD.product_name_snapshot
    OR NEW.warehouse_code_snapshot IS DISTINCT FROM OLD.warehouse_code_snapshot
    OR NEW.warehouse_name_snapshot IS DISTINCT FROM OLD.warehouse_name_snapshot
    OR NEW.base_uom_name_snapshot IS DISTINCT FROM OLD.base_uom_name_snapshot
    OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_LINE_SOURCE_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER guard_purchase_daily_batch_history
BEFORE UPDATE OR DELETE ON public.purchase_daily_batches
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_daily_batch();
CREATE TRIGGER guard_purchase_daily_batch_line_history
BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_daily_batch_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_daily_batch_line();
CREATE TRIGGER guard_purchase_daily_operation_history
BEFORE UPDATE OR DELETE ON public.purchase_daily_batch_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_daily_runtime_history();
CREATE TRIGGER guard_purchase_daily_audit_history
BEFORE UPDATE OR DELETE ON public.purchase_daily_batch_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_daily_runtime_history();
CREATE TRIGGER guard_purchase_daily_order_allocation_history
BEFORE UPDATE OR DELETE ON public.purchase_daily_batch_order_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_daily_runtime_history();

CREATE FUNCTION private.purchase_daily_batch_snapshot(p_company_id uuid,p_batch_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'batch',to_jsonb(batch),
    'lines',COALESCE((SELECT jsonb_agg(to_jsonb(line) ORDER BY line.line_no,line.id)
      FROM public.purchase_daily_batch_lines line
      WHERE line.company_id=batch.company_id AND line.batch_id=batch.id),'[]'::jsonb),
    'supplierOrders',COALESCE((SELECT jsonb_agg(to_jsonb(document)
        ORDER BY document.order_no,document.id)
      FROM public.supplier_order_documents document
      WHERE document.company_id=batch.company_id
        AND document.purchase_daily_batch_id=batch.id),'[]'::jsonb),
    'orderAllocations',COALESCE((SELECT jsonb_agg(to_jsonb(allocation)
        ORDER BY allocation.created_at,allocation.id)
      FROM public.purchase_daily_batch_order_allocations allocation
      WHERE allocation.company_id=batch.company_id
        AND allocation.batch_id=batch.id),'[]'::jsonb))
  FROM public.purchase_daily_batches batch
  WHERE batch.company_id=p_company_id AND batch.id=p_batch_id
$$;

CREATE FUNCTION private.get_purchase_daily_auto_ro_candidates_core(
  p_company_id uuid,p_business_date date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_base jsonb;v_item jsonb;v_candidates jsonb:='[]'::jsonb;
  v_daily_open numeric;v_total_open numeric;v_requested numeric;v_status text;
  v_negative integer:=0;v_actionable integer:=0;v_covered integer:=0;v_blocked integer:=0;
BEGIN
  v_base:=private.get_purchase_daily_replenishment_candidates_core(
    p_company_id,p_business_date);
  FOR v_item IN SELECT item FROM jsonb_array_elements(v_base->'candidates') item LOOP
    SELECT COALESCE(sum(line.requested_base_qty),0) INTO v_daily_open
    FROM public.purchase_daily_batch_lines line
    JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
      AND batch.id=line.batch_id
    WHERE line.company_id=p_company_id AND batch.status='DRAFT'
      AND line.product_id=(v_item->>'productId')::uuid
      AND line.warehouse_id=(v_item->>'sourceWarehouseId')::uuid;
    v_total_open:=(v_item->>'openPurchaseBaseQty')::numeric+v_daily_open;
    v_requested:=private.purchase_uncovered_negative_qty(
      (v_item->>'onHandBaseQty')::numeric,v_total_open);
    v_status:=CASE
      WHEN v_item->>'status' IN('OPEN_REQUEST_WAREHOUSE_AMBIGUOUS',
        'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED')
        THEN v_item->>'status'
      WHEN v_requested=0 THEN 'FULLY_COVERED'
      WHEN v_item->>'suggestedSupplierId' IS NULL THEN 'SUPPLIER_PENDING'
      ELSE 'READY' END;
    v_item:=v_item||jsonb_build_object('openDailyRoBaseQty',v_daily_open,
      'openPurchaseBaseQty',v_total_open,'requestedBaseQty',v_requested,'status',v_status);
    v_candidates:=v_candidates||jsonb_build_array(v_item);v_negative:=v_negative+1;
    IF v_requested>0 AND v_status IN('READY','SUPPLIER_PENDING') THEN
      v_actionable:=v_actionable+1;
    ELSIF v_status='FULLY_COVERED' THEN v_covered:=v_covered+1;
    ELSIF v_status IN('OPEN_REQUEST_WAREHOUSE_AMBIGUOUS','PRODUCT_INACTIVE',
      'SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED') THEN
      v_blocked:=v_blocked+1;
    END IF;
  END LOOP;
  RETURN v_base||jsonb_build_object('generationActive',(v_base->>'mode')='AUTO_RO',
    'summary',jsonb_build_object('negativeOnHandRows',v_negative,
      'actionableRows',v_actionable,'coveredRows',v_covered,'blockedRows',v_blocked),
    'candidates',v_candidates);
END
$$;

CREATE OR REPLACE FUNCTION public.get_purchase_daily_replenishment_preview()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_date date;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date INTO v_date
  FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_date IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  RETURN private.get_purchase_daily_auto_ro_candidates_core(v_company,v_date);
END
$$;

CREATE FUNCTION private.generate_purchase_daily_auto_ro_core(
  p_company_id uuid,p_business_date date,p_actor_id uuid,p_operation_id uuid,
  p_effective_at timestamptz
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_setting public.company_purchase_replenishment_settings%rowtype;
  v_timezone text;v_local_date date;v_local_time time;v_cutoff timestamptz;
  v_existing public.purchase_daily_batch_operations%rowtype;v_batch uuid;v_batch_no text;
  v_preview jsonb;v_candidate jsonb;v_line_no integer:=0;v_total numeric(24,6):=0;
  v_hash text;v_result jsonb;v_after jsonb;
BEGIN
  IF p_company_id IS NULL OR p_business_date IS NULL OR p_actor_id IS NULL
    OR p_operation_id IS NULL OR p_effective_at IS NULL THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_CONTEXT_REQUIRED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile WHERE profile.id=p_actor_id) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_ACTOR_NOT_FOUND';
  END IF;
  v_hash:=md5(jsonb_build_object('companyId',p_company_id,
    'businessDate',p_business_date,'operation','GENERATE_AUTO_RO')::text);
  SELECT * INTO v_existing FROM public.purchase_daily_batch_operations operation
  WHERE operation.company_id=p_company_id AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.operation_type<>'GENERATE_AUTO_RO' OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
    END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':PURCHASE_DAILY_REPLENISHMENT',0));
  SELECT * INTO v_existing FROM public.purchase_daily_batch_operations operation
  WHERE operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.company_id<>p_company_id
      OR v_existing.operation_type<>'GENERATE_AUTO_RO'
      OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
    END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  SELECT setting.* INTO v_setting
  FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=p_company_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND'; END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF v_setting.replenishment_mode<>'AUTO_RO' THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_MODE_REQUIRED';
  END IF;
  v_local_date:=(p_effective_at AT TIME ZONE v_timezone)::date;
  v_local_time:=(p_effective_at AT TIME ZONE v_timezone)::time;
  IF p_business_date<>v_local_date THEN RAISE EXCEPTION 'PURCHASE_AUTO_RO_BUSINESS_DATE_INVALID'; END IF;
  IF v_local_time<v_setting.cutoff_local_time THEN RAISE EXCEPTION 'PURCHASE_AUTO_RO_CUTOFF_NOT_REACHED'; END IF;
  v_cutoff:=(p_business_date+v_setting.cutoff_local_time) AT TIME ZONE v_timezone;

  SELECT batch.id INTO v_batch FROM public.purchase_daily_batches batch
  WHERE batch.company_id=p_company_id AND batch.business_date=p_business_date FOR UPDATE;
  IF FOUND THEN
    IF (SELECT mode_snapshot FROM public.purchase_daily_batches
        WHERE company_id=p_company_id AND id=v_batch)<>'AUTO_RO' THEN
      RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_MODE_CONFLICT';
    END IF;
    v_result:=jsonb_build_object('batchId',v_batch,
      'batchNo',(SELECT batch_no FROM public.purchase_daily_batches
        WHERE company_id=p_company_id AND id=v_batch),
      'created',false,'existingBatch',true,'exactRetry',false);
    INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,
      operation_type,request_hash,result_snapshot,actor_id)
    VALUES(p_operation_id,p_company_id,v_batch,'GENERATE_AUTO_RO',v_hash,v_result,p_actor_id);
    v_after:=private.purchase_daily_batch_snapshot(p_company_id,v_batch);
    INSERT INTO public.purchase_daily_batch_audit(company_id,batch_id,operation_id,
      action,actor_id,before_state,after_state)
    VALUES(p_company_id,v_batch,p_operation_id,'REUSE',p_actor_id,v_after,v_after);
    RETURN v_result;
  END IF;

  -- Serialize against Stock posting for every currently negative Product-Warehouse.
  PERFORM 1 FROM public.product_stocks stock
  WHERE stock.company_id=p_company_id AND stock.stock_qty<0
  ORDER BY stock.product_id,stock.warehouse_id FOR UPDATE;
  v_preview:=private.get_purchase_daily_auto_ro_candidates_core(
    p_company_id,p_business_date);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_preview->'candidates') item
      WHERE (item->>'requestedBaseQty')::numeric>0
        AND item->>'status'<>'FULLY_COVERED') THEN
    v_result:=jsonb_build_object('batchId',NULL,'batchNo',NULL,
      'created',false,'existingBatch',false,'noDemand',true,'exactRetry',false);
    INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,
      operation_type,request_hash,result_snapshot,actor_id)
    VALUES(p_operation_id,p_company_id,NULL,'GENERATE_AUTO_RO',v_hash,v_result,p_actor_id);
    RETURN v_result;
  END IF;

  v_batch_no:='RO-'||to_char(p_business_date,'YYYYMMDD')||'-'||
    lpad(nextval('private.purchase_daily_batch_no_seq')::text,10,'0');
  INSERT INTO public.purchase_daily_batches(company_id,batch_no,business_date,
    mode_snapshot,status,cutoff_at,generated_by)
  VALUES(p_company_id,v_batch_no,p_business_date,'AUTO_RO','DRAFT',v_cutoff,p_actor_id)
  RETURNING id INTO v_batch;

  FOR v_candidate IN SELECT item FROM jsonb_array_elements(v_preview->'candidates') item
    WHERE (item->>'requestedBaseQty')::numeric>0 AND item->>'status'<>'FULLY_COVERED'
    ORDER BY item->>'sourceWarehouseName',item->>'productName',item->>'productId'
  LOOP
    v_line_no:=v_line_no+1;
    INSERT INTO public.purchase_daily_batch_lines(company_id,batch_id,line_no,
      product_id,warehouse_id,base_uom_id,on_hand_snapshot,
      open_purchase_base_qty_snapshot,requested_base_qty,
      suggested_product_supplier_id,suggested_supplier_id,
      supplier_assignment_status,product_sku_snapshot,product_name_snapshot,
      warehouse_code_snapshot,warehouse_name_snapshot,base_uom_name_snapshot,
      destination_warehouse_id,requires_transfer,
      destination_warehouse_code_snapshot,destination_warehouse_name_snapshot,
      readiness_status)
    VALUES(p_company_id,v_batch,v_line_no,(v_candidate->>'productId')::uuid,
      (v_candidate->>'sourceWarehouseId')::uuid,(v_candidate->>'baseUomId')::uuid,
      (v_candidate->>'onHandBaseQty')::numeric,
      (v_candidate->>'openPurchaseBaseQty')::numeric,
      (v_candidate->>'requestedBaseQty')::numeric,
      NULLIF(v_candidate->>'suggestedProductSupplierId','')::uuid,
      NULLIF(v_candidate->>'suggestedSupplierId','')::uuid,
      v_candidate->>'supplierAssignmentStatus',v_candidate->>'productSku',
      v_candidate->>'productName',v_candidate->>'sourceWarehouseCode',
      v_candidate->>'sourceWarehouseName',v_candidate->>'baseUomName',
      NULLIF(v_candidate->>'destinationWarehouseId','')::uuid,
      COALESCE((v_candidate->>'requiresTransfer')::boolean,false),
      NULLIF(v_candidate->>'destinationWarehouseCode',''),
      NULLIF(v_candidate->>'destinationWarehouseName',''),v_candidate->>'status');
    v_total:=v_total+(v_candidate->>'requestedBaseQty')::numeric;
  END LOOP;

  INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,
    operation_type,request_hash,result_snapshot,actor_id)
  VALUES(p_operation_id,p_company_id,v_batch,'GENERATE_AUTO_RO',v_hash,
    jsonb_build_object('batchId',v_batch,'batchNo',v_batch_no,'created',true,
      'existingBatch',false,'lineCount',v_line_no,'requestedTotalBaseQty',v_total,
      'exactRetry',false),p_actor_id);
  UPDATE public.purchase_daily_batches SET generation_operation_id=p_operation_id,
    line_count=v_line_no,requested_total_base_qty=v_total,updated_at=p_effective_at
  WHERE company_id=p_company_id AND id=v_batch;
  v_after:=private.purchase_daily_batch_snapshot(p_company_id,v_batch);
  INSERT INTO public.purchase_daily_batch_audit(company_id,batch_id,operation_id,
    action,actor_id,before_state,after_state)
  VALUES(p_company_id,v_batch,p_operation_id,'GENERATE',p_actor_id,NULL,v_after);
  SELECT result_snapshot INTO v_result FROM public.purchase_daily_batch_operations
  WHERE company_id=p_company_id AND id=p_operation_id;
  RETURN v_result;
END
$$;

CREATE FUNCTION private.confirm_purchase_daily_auto_ro_core(
  p_company_id uuid,p_batch_id uuid,p_master_version bigint,p_operation_id uuid,
  p_actor_id uuid,p_allocations jsonb,p_effective_at timestamptz
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_batch public.purchase_daily_batches%rowtype;
  v_existing public.purchase_daily_batch_operations%rowtype;v_hash text;v_before jsonb;
  v_normalized jsonb:='[]'::jsonb;v_input jsonb;v_source record;
  v_destination record;v_uom record;v_qty numeric;v_base numeric;v_price numeric;
  v_relation_supplier uuid;v_relation_last_price numeric;
  v_relation_reference_price numeric;v_supplier_product_code text;
  v_supplier uuid;v_order uuid;v_order_no text;v_order_line uuid;v_line_no integer;
  v_group_count integer:=0;v_result jsonb;v_after jsonb;v_company_date date;
  v_group record;v_row record;v_total numeric;v_count integer;
BEGIN
  IF p_company_id IS NULL OR p_batch_id IS NULL OR p_master_version IS NULL
    OR p_operation_id IS NULL OR p_actor_id IS NULL OR p_effective_at IS NULL THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_CONFIRM_CONTEXT_REQUIRED';
  END IF;
  IF p_allocations IS NULL OR jsonb_typeof(p_allocations)<>'array'
    OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_ALLOCATIONS_REQUIRED';
  END IF;
  v_hash:=md5(jsonb_build_object('companyId',p_company_id,'batchId',p_batch_id,
    'expectedVersion',p_master_version,'allocations',p_allocations)::text);
  SELECT * INTO v_existing FROM public.purchase_daily_batch_operations operation
  WHERE operation.company_id=p_company_id AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.operation_type<>'CONFIRM_AUTO_RO' OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
    END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':PURCHASE_DAILY_REPLENISHMENT',0));
  SELECT * INTO v_existing FROM public.purchase_daily_batch_operations operation
  WHERE operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.company_id<>p_company_id
      OR v_existing.operation_type<>'CONFIRM_AUTO_RO'
      OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
    END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  SELECT * INTO v_batch FROM public.purchase_daily_batches batch
  WHERE batch.company_id=p_company_id AND batch.id=p_batch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_NOT_FOUND'; END IF;
  IF v_batch.mode_snapshot<>'AUTO_RO' THEN RAISE EXCEPTION 'PURCHASE_AUTO_RO_BATCH_REQUIRED'; END IF;
  IF v_batch.status<>'DRAFT' THEN RAISE EXCEPTION 'PURCHASE_AUTO_RO_NOT_DRAFT'; END IF;
  IF v_batch.master_version<>p_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF (SELECT count(DISTINCT NULLIF(item->>'batchLineId','')::uuid)
      FROM jsonb_array_elements(p_allocations) item)<>
     (SELECT count(*) FROM public.purchase_daily_batch_lines line
      WHERE line.company_id=p_company_id AND line.batch_id=p_batch_id) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_ALL_LINES_REQUIRED';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_allocations) item
      LEFT JOIN public.purchase_daily_batch_lines line
        ON line.company_id=p_company_id AND line.batch_id=p_batch_id
       AND line.id=NULLIF(item->>'batchLineId','')::uuid
      WHERE line.id IS NULL) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_ALLOCATION_LINE_INVALID';
  END IF;
  v_before:=private.purchase_daily_batch_snapshot(p_company_id,p_batch_id);
  SELECT (p_effective_at AT TIME ZONE company.timezone)::date INTO v_company_date
  FROM public.companies company WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF v_company_date IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;

  FOR v_input IN SELECT item FROM jsonb_array_elements(p_allocations) item LOOP
    SELECT line.*,product.uom_id product_base_uom_id,product.sku,product.name
    INTO v_source FROM public.purchase_daily_batch_lines line
    JOIN public.products product ON product.company_id=line.company_id
      AND product.id=line.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.warehouses source_warehouse ON source_warehouse.company_id=line.company_id
      AND source_warehouse.id=line.warehouse_id AND source_warehouse.is_active
      AND source_warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
    WHERE line.company_id=p_company_id AND line.batch_id=p_batch_id
      AND line.id=NULLIF(v_input->>'batchLineId','')::uuid FOR UPDATE OF line;
    IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_AUTO_RO_SOURCE_LINE_INVALID'; END IF;
    IF v_source.readiness_status='OPEN_REQUEST_WAREHOUSE_AMBIGUOUS' THEN
      RAISE EXCEPTION 'OPEN_REQUEST_WAREHOUSE_AMBIGUOUS';
    END IF;
    IF COALESCE((v_input->>'batchLineVersion')::bigint,0)<>v_source.master_version THEN
      RAISE EXCEPTION 'PURCHASE_AUTO_RO_LINE_VERSION_CONFLICT';
    END IF;
    SELECT warehouse.id,warehouse.code,warehouse.name INTO v_destination
    FROM public.warehouses warehouse
    WHERE warehouse.company_id=p_company_id
      AND warehouse.id=NULLIF(v_input->>'destinationWarehouseId','')::uuid
      AND warehouse.is_active AND warehouse.is_purchase_destination
      AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT';
    IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_RECEIPT_WAREHOUSE_INVALID'; END IF;
    v_qty:=(v_input->>'orderedQty')::numeric;
    IF v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'PURCHASE_AUTO_RO_QUANTITY_INVALID'; END IF;
    SELECT product_uom.factor_to_base,uom.name,uom.allow_decimal,uom.decimal_precision
    INTO v_uom FROM public.product_uoms product_uom
    JOIN public.uoms uom ON uom.company_id=product_uom.company_id
      AND uom.id=product_uom.uom_id AND uom.is_active
    WHERE product_uom.company_id=p_company_id AND product_uom.product_id=v_source.product_id
      AND product_uom.uom_id=NULLIF(v_input->>'purchaseUomId','')::uuid
      AND product_uom.is_active AND (product_uom.purchase_allowed OR (
        NULLIF(v_input->>'productSupplierId','') IS NULL
        AND product_uom.uom_id=v_source.base_uom_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND'; END IF;
    IF NOT v_uom.allow_decimal AND v_qty<>trunc(v_qty) THEN
      RAISE EXCEPTION 'PURCHASE_UOM_REQUIRES_INTEGER';
    END IF;
    IF v_uom.allow_decimal AND v_qty<>round(v_qty,v_uom.decimal_precision) THEN
      RAISE EXCEPTION 'PURCHASE_UOM_PRECISION_EXCEEDED';
    END IF;
    v_base:=v_qty*v_uom.factor_to_base;
    v_relation_supplier:=NULL;v_relation_last_price:=NULL;
    v_relation_reference_price:=NULL;v_supplier_product_code:=NULL;
    IF NULLIF(v_input->>'productSupplierId','') IS NULL THEN
      v_supplier:=NULL;
      IF NULLIF(v_input->>'purchaseUomId','')::uuid<>v_source.base_uom_id THEN
        RAISE EXCEPTION 'SUPPLIER_PENDING_MUST_USE_BASE_UOM';
      END IF;
    ELSE
      SELECT relation.supplier_id,relation.last_purchase_price,
        relation.reference_purchase_price,relation.supplier_product_code
      INTO v_relation_supplier,v_relation_last_price,
        v_relation_reference_price,v_supplier_product_code
      FROM public.product_suppliers relation
      JOIN public.suppliers master_supplier ON master_supplier.company_id=relation.company_id
        AND master_supplier.id=relation.supplier_id AND master_supplier.is_active
      WHERE relation.company_id=p_company_id
        AND relation.id=(v_input->>'productSupplierId')::uuid
        AND relation.product_id=v_source.product_id AND relation.is_active
        AND relation.purchase_uom_id=(v_input->>'purchaseUomId')::uuid;
      IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PRODUCT_SUPPLIER_NOT_FOUND'; END IF;
      v_supplier:=v_relation_supplier;
    END IF;
    v_price:=COALESCE(NULLIF(v_input->>'estimatedUnitPrice','')::numeric,
      v_relation_last_price,v_relation_reference_price,0);
    IF v_price<0 THEN RAISE EXCEPTION 'SUPPLIER_ORDER_PRICE_INVALID'; END IF;
    v_normalized:=v_normalized||jsonb_build_array(jsonb_build_object(
      'batchLineId',v_source.id,'productId',v_source.product_id,
      'productSku',v_source.product_sku_snapshot,'productName',v_source.product_name_snapshot,
      'sourceWarehouseId',v_source.warehouse_id,'destinationWarehouseId',v_destination.id,
      'destinationWarehouseCode',v_destination.code,'destinationWarehouseName',v_destination.name,
      'supplierId',v_supplier,'purchaseUomId',(v_input->>'purchaseUomId')::uuid,
      'purchaseUomName',v_uom.name,'factorToBase',v_uom.factor_to_base,
      'orderedQty',v_qty,'orderedBaseQty',v_base,'estimatedUnitPrice',v_price,
      'supplierProductCode',v_supplier_product_code));
  END LOOP;

  IF EXISTS(SELECT 1 FROM jsonb_to_recordset(v_normalized) AS allocation(
      "batchLineId" uuid,"destinationWarehouseId" uuid)
      GROUP BY "batchLineId" HAVING count(DISTINCT "destinationWarehouseId")<>1) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_LINE_DESTINATION_MUST_BE_SINGLE';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_to_recordset(v_normalized) AS allocation(
      "batchLineId" uuid,"supplierId" uuid,"purchaseUomId" uuid,
      "destinationWarehouseId" uuid)
      GROUP BY "batchLineId","supplierId","purchaseUomId","destinationWarehouseId"
      HAVING count(*)>1) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_DUPLICATE_ALLOCATION';
  END IF;
  FOR v_row IN SELECT allocation."batchLineId" batch_line_id,
      min(allocation."destinationWarehouseId"::text)::uuid destination_id,
      min(allocation."destinationWarehouseCode") destination_code,
      min(allocation."destinationWarehouseName") destination_name,
      sum(allocation."orderedBaseQty") total_base
    FROM jsonb_to_recordset(v_normalized) AS allocation(
      "batchLineId" uuid,"destinationWarehouseId" uuid,
      "destinationWarehouseCode" text,"destinationWarehouseName" text,
      "orderedBaseQty" numeric)
    GROUP BY allocation."batchLineId"
  LOOP
    UPDATE public.purchase_daily_batch_lines line SET
      destination_warehouse_id=v_row.destination_id,
      destination_warehouse_code_snapshot=v_row.destination_code,
      destination_warehouse_name_snapshot=v_row.destination_name,
      requires_transfer=v_row.destination_id<>line.warehouse_id,
      requested_base_qty=v_row.total_base,readiness_status='ORDERED',
      master_version=line.master_version+1
    WHERE line.company_id=p_company_id AND line.id=v_row.batch_line_id;
  END LOOP;

  FOR v_group IN SELECT DISTINCT allocation."supplierId" supplier_id
    FROM jsonb_to_recordset(v_normalized) AS allocation("supplierId" uuid)
    ORDER BY allocation."supplierId" NULLS LAST
  LOOP
    v_supplier:=v_group.supplier_id;v_line_no:=0;v_total:=0;v_count:=0;
    v_order_no:='PO-'||to_char(v_company_date,'YYYYMMDD')||'-'||
      lpad(nextval('private.supplier_order_document_no_seq')::text,10,'0');
    INSERT INTO public.supplier_order_documents(company_id,order_no,store_id,
      destination_warehouse_id,supplier_id,order_date,expected_date,ordered_by,
      status,notes,order_source,document_scope,purchase_daily_batch_id,
      supplier_assignment_status)
    VALUES(p_company_id,v_order_no,NULL,NULL,v_supplier,v_company_date,NULL,p_actor_id,
      'DRAFT','Dibuat dari '||v_batch.batch_no,'DAILY_REPLENISHMENT',
      'COMPANY_MULTI_WAREHOUSE',p_batch_id,
      CASE WHEN v_supplier IS NULL THEN 'SUPPLIER_PENDING' ELSE 'ASSIGNED' END)
    RETURNING id INTO v_order;
    INSERT INTO public.supplier_order_audit(company_id,document_id,action,actor_id,
      before_state,after_state)
    SELECT p_company_id,v_order,'CREATE',p_actor_id,NULL,to_jsonb(document)
    FROM public.supplier_order_documents document
    WHERE document.company_id=p_company_id AND document.id=v_order;

    FOR v_row IN SELECT * FROM jsonb_to_recordset(v_normalized) AS allocation(
        "batchLineId" uuid,"productId" uuid,"productSku" text,"productName" text,
        "sourceWarehouseId" uuid,"destinationWarehouseId" uuid,"supplierId" uuid,
        "purchaseUomId" uuid,"purchaseUomName" text,"factorToBase" numeric,
        "orderedQty" numeric,"orderedBaseQty" numeric,"estimatedUnitPrice" numeric,
        "supplierProductCode" text)
      WHERE allocation."supplierId" IS NOT DISTINCT FROM v_supplier
      ORDER BY allocation."productName",allocation."batchLineId"
    LOOP
      v_line_no:=v_line_no+1;v_count:=v_count+1;
      v_total:=v_total+round(v_row."orderedQty"*v_row."estimatedUnitPrice",4);
      INSERT INTO public.supplier_order_lines(company_id,document_id,line_no,
        client_line_key,product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,
        ordered_base_qty,estimated_unit_price,estimated_subtotal,
        product_sku_snapshot,product_name_snapshot,ordered_uom_name_snapshot,
        supplier_product_code_snapshot,source_warehouse_id,destination_warehouse_id)
      VALUES(p_company_id,v_order,v_line_no,gen_random_uuid(),v_row."productId",
        v_row."purchaseUomId",v_row."orderedQty",v_row."factorToBase",
        v_row."orderedBaseQty",v_row."estimatedUnitPrice",
        round(v_row."orderedQty"*v_row."estimatedUnitPrice",4),v_row."productSku",
        v_row."productName",v_row."purchaseUomName",v_row."supplierProductCode",
        v_row."sourceWarehouseId",v_row."destinationWarehouseId")
      RETURNING id INTO v_order_line;
      INSERT INTO public.purchase_daily_batch_order_allocations(company_id,batch_id,
        batch_line_id,supplier_order_id,supplier_order_line_id,allocated_base_qty,created_by)
      VALUES(p_company_id,p_batch_id,v_row."batchLineId",v_order,v_order_line,
        v_row."orderedBaseQty",p_actor_id);
    END LOOP;
    UPDATE public.supplier_order_documents SET line_count=v_count,
      total_ordered_base_qty=(SELECT sum(line.ordered_base_qty)
        FROM public.supplier_order_lines line
        WHERE line.company_id=p_company_id AND line.document_id=v_order),
      estimated_total=v_total,status='CONFIRMED',confirmed_by=p_actor_id,
      confirmed_at=p_effective_at,
      confirmation_idempotency_key=md5(p_operation_id::text||':'||
        COALESCE(v_supplier::text,'SUPPLIER_PENDING'))::uuid,
      master_version=master_version+1,updated_at=p_effective_at
    WHERE company_id=p_company_id AND id=v_order;
    INSERT INTO public.supplier_order_audit(company_id,document_id,action,actor_id,
      before_state,after_state)
    SELECT p_company_id,v_order,'CONFIRM',p_actor_id,NULL,to_jsonb(document)
    FROM public.supplier_order_documents document
    WHERE document.company_id=p_company_id AND document.id=v_order;
    v_group_count:=v_group_count+1;
  END LOOP;

  SELECT count(*),sum(requested_base_qty) INTO v_count,v_total
  FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=p_company_id AND line.batch_id=p_batch_id;
  v_result:=jsonb_build_object('batchId',p_batch_id,'batchNo',v_batch.batch_no,
    'status','READY','supplierOrderCount',v_group_count,'lineCount',v_count,
    'requestedTotalBaseQty',v_total,'exactRetry',false);
  INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,
    operation_type,request_hash,result_snapshot,actor_id)
  VALUES(p_operation_id,p_company_id,p_batch_id,'CONFIRM_AUTO_RO',v_hash,v_result,p_actor_id);
  UPDATE public.purchase_daily_batches SET status='READY',line_count=v_count,
    requested_total_base_qty=v_total,confirmed_by=p_actor_id,confirmed_at=p_effective_at,
    confirmation_operation_id=p_operation_id,master_version=master_version+1,
    updated_at=p_effective_at WHERE company_id=p_company_id AND id=p_batch_id;
  v_after:=private.purchase_daily_batch_snapshot(p_company_id,p_batch_id);
  INSERT INTO public.purchase_daily_batch_audit(company_id,batch_id,operation_id,
    action,actor_id,before_state,after_state)
  VALUES(p_company_id,p_batch_id,p_operation_id,'CONFIRM',p_actor_id,v_before,v_after);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.generate_purchase_daily_auto_ro(
  p_business_date date,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','CREATE_DRAFT');
  RETURN private.generate_purchase_daily_auto_ro_core(v_company,p_business_date,
    v_actor,p_operation_id,clock_timestamp());
END
$$;

CREATE FUNCTION public.confirm_purchase_daily_auto_ro(
  p_batch_id uuid,p_master_version bigint,p_operation_id uuid,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','POST');
  RETURN private.confirm_purchase_daily_auto_ro_core(v_company,p_batch_id,
    p_master_version,p_operation_id,v_actor,p_allocations,clock_timestamp());
END
$$;

CREATE FUNCTION public.get_purchase_daily_auto_ro_workspace()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  RETURN jsonb_build_object('companyId',v_company,
    'batches',COALESCE((SELECT jsonb_agg(to_jsonb(batch)
      ORDER BY batch.business_date DESC,batch.batch_no DESC)
      FROM public.purchase_daily_batches batch WHERE batch.company_id=v_company),'[]'::jsonb),
    'lines',COALESCE((SELECT jsonb_agg(to_jsonb(line)
      ORDER BY line.batch_id,line.line_no)
      FROM public.purchase_daily_batch_lines line WHERE line.company_id=v_company),'[]'::jsonb),
    'supplierOrders',COALESCE((SELECT jsonb_agg(to_jsonb(document)
      ORDER BY document.created_at DESC,document.order_no)
      FROM public.supplier_order_documents document
      WHERE document.company_id=v_company
        AND document.order_source='DAILY_REPLENISHMENT'),'[]'::jsonb),
    'allocations',COALESCE((SELECT jsonb_agg(to_jsonb(allocation)
      ORDER BY allocation.created_at,allocation.id)
      FROM public.purchase_daily_batch_order_allocations allocation
      WHERE allocation.company_id=v_company),'[]'::jsonb));
END
$$;

ALTER TABLE public.purchase_daily_batch_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_daily_batch_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_daily_batch_order_allocations ENABLE ROW LEVEL SECURITY;
CREATE POLICY purchase_daily_batch_operations_read ON public.purchase_daily_batch_operations
  FOR SELECT TO authenticated USING(public.private_request_company_matches(company_id));
CREATE POLICY purchase_daily_batch_audit_read ON public.purchase_daily_batch_audit
  FOR SELECT TO authenticated USING(public.private_request_company_matches(company_id));
CREATE POLICY purchase_daily_batch_order_allocations_read
  ON public.purchase_daily_batch_order_allocations FOR SELECT TO authenticated
  USING(public.private_request_company_matches(company_id));

REVOKE ALL ON TABLE public.purchase_daily_batch_operations,
  public.purchase_daily_batch_audit,public.purchase_daily_batch_order_allocations
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.purchase_daily_batch_operations,
  public.purchase_daily_batch_audit,public.purchase_daily_batch_order_allocations
TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.purchase_daily_batch_operations,
  public.purchase_daily_batch_audit,public.purchase_daily_batch_order_allocations
TO service_role;
REVOKE ALL ON FUNCTION private.trg_guard_purchase_daily_runtime_history(),
  private.trg_guard_purchase_daily_batch(),private.trg_guard_purchase_daily_batch_line(),
  private.purchase_daily_batch_snapshot(uuid,uuid),
  private.get_purchase_daily_auto_ro_candidates_core(uuid,date),
  private.generate_purchase_daily_auto_ro_core(uuid,date,uuid,uuid,timestamptz),
  private.confirm_purchase_daily_auto_ro_core(uuid,uuid,bigint,uuid,uuid,jsonb,timestamptz)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_purchase_daily_runtime_history(),
  private.trg_guard_purchase_daily_batch(),private.trg_guard_purchase_daily_batch_line(),
  private.purchase_daily_batch_snapshot(uuid,uuid),
  private.get_purchase_daily_auto_ro_candidates_core(uuid,date),
  private.generate_purchase_daily_auto_ro_core(uuid,date,uuid,uuid,timestamptz),
  private.confirm_purchase_daily_auto_ro_core(uuid,uuid,bigint,uuid,uuid,jsonb,timestamptz)
TO service_role;
REVOKE ALL ON FUNCTION public.generate_purchase_daily_auto_ro(date,uuid),
  public.confirm_purchase_daily_auto_ro(uuid,bigint,uuid,jsonb),
  public.get_purchase_daily_auto_ro_workspace() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.generate_purchase_daily_auto_ro(date,uuid),
  public.confirm_purchase_daily_auto_ro(uuid,bigint,uuid,jsonb),
  public.get_purchase_daily_auto_ro_workspace() TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260913120000','purchase_daily_auto_ro_runtime',
  'Step 3/6 atomic Company-level AUTO_RO generation, editable split allocations, Supplier-assigned and SUPPLIER_PENDING PO groups, immutable lineage/audit and zero Receipt/Stock/FIFO/AP/Finance effect');
NOTIFY pgrst,'reload schema';
COMMIT;

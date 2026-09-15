-- Atomic manual installation: no recovery execution, no operational backfill.
-- Generated from the six reviewed migrations; each retains its own guards.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
DO $install_20260915140000$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915140000') THEN
 EXECUTE $release_20260915140000$
-- Recovery foundation only. DOES NOT enable conversion or repair live orders.

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260915140000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260828190000','20260911130000'))<>2
    OR to_regclass('public.sales_cutover_procurement_links') IS NOT NULL
    OR to_regprocedure('private.link_sales_cutover_procurement(uuid,uuid,uuid,uuid,uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_order_procurement_links(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: procurement lineage dependency/collision';
  END IF;
END
$guard$;

CREATE TABLE public.sales_cutover_procurement_links(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  source_sales_id uuid NOT NULL,
  source_demand_line_id uuid NOT NULL,
  target_sales_order_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  source_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_cutover_procurement_link_company_unique UNIQUE(company_id,id),
  CONSTRAINT sales_cutover_procurement_link_demand_unique UNIQUE(company_id,source_demand_line_id),
  CONSTRAINT sales_cutover_procurement_link_source_fk FOREIGN KEY(company_id,source_sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_cutover_procurement_link_demand_fk FOREIGN KEY(company_id,source_demand_line_id)
    REFERENCES public.sales_order_procurement_demand_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_cutover_procurement_link_target_fk FOREIGN KEY(company_id,target_sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_cutover_procurement_link_operation_fk FOREIGN KEY(company_id,operation_id)
    REFERENCES public.backoffice_sales_order_operations(company_id,operation_id) ON DELETE RESTRICT,
  CONSTRAINT sales_cutover_procurement_link_snapshot_check CHECK(jsonb_typeof(source_snapshot)='object')
);
CREATE INDEX sales_cutover_procurement_link_target_index
  ON public.sales_cutover_procurement_links(company_id,target_sales_order_id);
ALTER TABLE public.sales_cutover_procurement_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_cutover_procurement_links FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON public.sales_cutover_procurement_links TO service_role;

CREATE FUNCTION private.trg_guard_sales_cutover_procurement_link()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'CUTOVER_PROCUREMENT_LINK_IMMUTABLE'; END IF;
  IF COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')<>'1'
    OR auth.uid() IS DISTINCT FROM NEW.actor_id
    OR public.private_active_company_id() IS DISTINCT FROM NEW.company_id
    OR NOT EXISTS(SELECT 1 FROM public.profiles actor
      WHERE actor.id=NEW.actor_id AND actor.role::text='super_admin') THEN
    RAISE EXCEPTION 'CUTOVER_PROCUREMENT_LINK_CONTEXT_INVALID';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_lines demand
    JOIN public.backoffice_sales_orders target ON target.company_id=demand.company_id
      AND target.id=NEW.target_sales_order_id
    JOIN public.backoffice_sales_order_operations operation ON operation.company_id=target.company_id
      AND operation.sales_order_id=target.id AND operation.operation_id=NEW.operation_id
    WHERE demand.company_id=NEW.company_id AND demand.id=NEW.source_demand_line_id
      AND demand.sales_id=NEW.source_sales_id AND operation.actor_id=NEW.actor_id
      AND operation.operation_type='SAVE_DRAFT'
      AND target.commercial_snapshot->>'cutoverSourceDocumentId'=NEW.source_sales_id::text
      AND NEW.source_snapshot->'demandLine'=to_jsonb(demand)) THEN
    RAISE EXCEPTION 'CUTOVER_PROCUREMENT_LINK_SCOPE_INVALID';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER sales_cutover_procurement_link_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.sales_cutover_procurement_links
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_sales_cutover_procurement_link();

CREATE FUNCTION private.link_sales_cutover_procurement(
  p_company_id uuid,p_source_sales_id uuid,p_target_sales_order_id uuid,
  p_actor_id uuid,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_line public.sales_order_procurement_demand_lines%rowtype;
  v_existing public.sales_cutover_procurement_links%rowtype;
  v_snapshot jsonb;v_count integer:=0;
BEGIN
  IF p_company_id IS NULL OR p_source_sales_id IS NULL OR p_target_sales_order_id IS NULL
    OR p_actor_id IS NULL OR p_operation_id IS NULL
    OR COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')<>'1'
    OR auth.uid() IS DISTINCT FROM p_actor_id
    OR public.private_active_company_id() IS DISTINCT FROM p_company_id
    OR NOT EXISTS(SELECT 1 FROM public.profiles actor
      WHERE actor.id=p_actor_id AND actor.role::text='super_admin') THEN
    RAISE EXCEPTION 'CUTOVER_PROCUREMENT_LINK_CONTEXT_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text||':sales-process-cutover',0));
  PERFORM 1 FROM public.sales_headers source WHERE source.company_id=p_company_id
    AND source.id=p_source_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUTOVER_SOURCE_RETAIL_NOT_FOUND'; END IF;
  PERFORM 1 FROM public.backoffice_sales_orders target
    JOIN public.backoffice_sales_order_operations operation ON operation.company_id=target.company_id
      AND operation.sales_order_id=target.id AND operation.operation_id=p_operation_id
    WHERE target.company_id=p_company_id AND target.id=p_target_sales_order_id
      AND target.commercial_snapshot->>'cutoverSourceDocumentId'=p_source_sales_id::text
      AND operation.actor_id=p_actor_id AND operation.operation_type='SAVE_DRAFT'
    FOR UPDATE OF target;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUTOVER_PROCUREMENT_LINK_SCOPE_INVALID'; END IF;
  -- Serialize snapshots with the canonical demand/request writers. Shared
  -- request lines stay one identity; do not copy or aggregate them into new RO.
  PERFORM 1 FROM public.sales_order_procurement_demands header
    WHERE header.company_id=p_company_id AND EXISTS(
      SELECT 1 FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=header.company_id AND line.demand_id=header.id
        AND line.sales_id=p_source_sales_id) ORDER BY header.id FOR UPDATE;
  PERFORM 1 FROM public.stock_request_documents request
    WHERE request.company_id=p_company_id AND EXISTS(
      SELECT 1 FROM public.sales_order_procurement_demands header
      JOIN public.sales_order_procurement_demand_lines line ON line.company_id=header.company_id
        AND line.demand_id=header.id
      WHERE header.company_id=request.company_id AND header.stock_request_document_id=request.id
        AND line.sales_id=p_source_sales_id) ORDER BY request.id FOR UPDATE;
  PERFORM 1 FROM public.stock_request_lines request_line
    WHERE request_line.company_id=p_company_id AND EXISTS(
      SELECT 1 FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=request_line.company_id AND line.stock_request_line_id=request_line.id
        AND line.sales_id=p_source_sales_id) ORDER BY request_line.id FOR UPDATE;
  FOR v_line IN SELECT demand.* FROM public.sales_order_procurement_demand_lines demand
    WHERE demand.company_id=p_company_id AND demand.sales_id=p_source_sales_id
      AND demand.status IN('OPEN','REQUESTED','ORDERED','AMENDMENT_REQUIRED')
    ORDER BY demand.id FOR UPDATE
  LOOP
    SELECT * INTO v_existing FROM public.sales_cutover_procurement_links
      WHERE company_id=p_company_id AND source_demand_line_id=v_line.id;
    IF FOUND THEN
      IF v_existing.source_sales_id<>p_source_sales_id
        OR v_existing.target_sales_order_id<>p_target_sales_order_id
        OR v_existing.operation_id<>p_operation_id OR v_existing.actor_id<>p_actor_id THEN
        RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
      END IF;
    ELSE
      v_snapshot:=jsonb_build_object('demandLine',to_jsonb(v_line),
        'stockRequestLine',(SELECT to_jsonb(request_line) FROM public.stock_request_lines request_line
          WHERE request_line.company_id=p_company_id AND request_line.id=v_line.stock_request_line_id),
        'stockRequest',(SELECT to_jsonb(request) FROM public.sales_order_procurement_demands header
          JOIN public.stock_request_documents request ON request.company_id=header.company_id
            AND request.id=header.stock_request_document_id
          WHERE header.company_id=p_company_id AND header.id=v_line.demand_id));
      INSERT INTO public.sales_cutover_procurement_links(company_id,source_sales_id,
        source_demand_line_id,target_sales_order_id,operation_id,actor_id,source_snapshot)
      VALUES(p_company_id,p_source_sales_id,v_line.id,p_target_sales_order_id,
        p_operation_id,p_actor_id,v_snapshot);
    END IF;
    v_count:=v_count+1;
  END LOOP;
  RETURN jsonb_build_object('companyId',p_company_id,'sourceSalesId',p_source_sales_id,
    'targetSalesOrderId',p_target_sales_order_id,'linkedDemandLines',v_count);
END
$$;

CREATE FUNCTION public.get_backoffice_sales_order_procurement_links(p_sales_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders target
    WHERE target.company_id=v_company AND target.id=p_sales_order_id) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'salesOrderId',p_sales_order_id,
    'links',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',link.id,'sourceSalesId',link.source_sales_id,'demandLineId',line.id,
      'stockProductId',line.stock_product_id,'warehouseId',line.warehouse_id,
      'stockRequestId',request.id,'stockRequestNo',request.request_no,
      'stockRequestStatus',request.status,'stockRequestLineId',line.stock_request_line_id,
      'demandStatus',line.status,'openDemandBaseQty',line.demand_base_qty-line.released_base_qty,
      'createdAt',link.created_at) ORDER BY link.created_at,link.id)
      FROM public.sales_cutover_procurement_links link
      JOIN public.sales_order_procurement_demand_lines line ON line.company_id=link.company_id
        AND line.id=link.source_demand_line_id
      JOIN public.sales_order_procurement_demands header ON header.company_id=line.company_id
        AND header.id=line.demand_id
      LEFT JOIN public.stock_request_documents request ON request.company_id=header.company_id
        AND request.id=header.stock_request_document_id
      WHERE link.company_id=v_company AND link.target_sales_order_id=p_sales_order_id),'[]'::jsonb));
END
$$;
REVOKE ALL ON FUNCTION private.trg_guard_sales_cutover_procurement_link(),
  private.link_sales_cutover_procurement(uuid,uuid,uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_sales_cutover_procurement_link(),
  private.link_sales_cutover_procurement(uuid,uuid,uuid,uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.get_backoffice_sales_order_procurement_links(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_order_procurement_links(uuid) TO authenticated,service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260915140000','sales_cutover_procurement_lineage_foundation',
  'Immutable tenant-scoped existing Demand/Stock Request to Office SO linkage; Sales VIEW reader; no conversion activation, operational mutation, or backfill');
NOTIFY pgrst,'reload schema';

$release_20260915140000$;
 END IF;
END $install_20260915140000$;
DO $install_20260915141000$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915141000') THEN
 EXECUTE $release_20260915141000$
-- Historical standalone lifecycle blocker is resolved by 20260915142000.
-- Install only with the full verified atomic release, never this runtime alone.
-- Preserve procurement identities and synchronize Office lifecycle; no live backfill.

DO $guard$
BEGIN
 IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915141000') THEN RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260915141000'; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915140000')
 OR to_regprocedure('private.reconcile_session_procurement_request(uuid,uuid,uuid,uuid)') IS NULL
 OR to_regprocedure('private.sync_managed_request_single_draft_po(uuid,uuid,uuid,uuid)') IS NULL
 OR to_regprocedure('private.refresh_procurement_before_cutover_retention(uuid,uuid,uuid,uuid,text)') IS NOT NULL
 OR to_regprocedure('private.sync_office_cutover_procurement(uuid,uuid,uuid,uuid)') IS NOT NULL
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: procurement retention dependencies/collision'; END IF;
 IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING'))
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cancel open cutover previews before upgrade'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
 OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance/offline queue'; END IF;
END $guard$;

ALTER FUNCTION private.refresh_sales_order_procurement_demand(uuid,uuid,uuid,uuid,text)
 RENAME TO refresh_procurement_before_cutover_retention;
CREATE FUNCTION private.refresh_sales_order_procurement_demand(
 p_company_id uuid,p_sales_id uuid,p_actor_id uuid,p_idempotency_key uuid,p_action text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_target uuid;v_link public.sales_cutover_procurement_links%rowtype;
BEGIN
 SELECT link.* INTO v_link FROM public.sales_cutover_procurement_links link
 WHERE link.company_id=p_company_id AND link.source_sales_id=p_sales_id ORDER BY link.id LIMIT 1;
 IF FOUND THEN
  v_target:=NULLIF(current_setting('kgs.cutover_procurement_target',true),'')::uuid;
  IF p_action IS DISTINCT FROM 'CANCEL'
   OR COALESCE(current_setting('kgs.sales_process_cutover_mutation',true),'')<>'1'
   OR v_target IS DISTINCT FROM v_link.target_sales_order_id
   OR auth.uid() IS DISTINCT FROM p_actor_id
   OR public.private_active_company_id() IS DISTINCT FROM p_company_id
   OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_actor_id AND role::text='super_admin')
   OR NOT EXISTS(SELECT 1 FROM public.sales_headers WHERE company_id=p_company_id
     AND id=p_sales_id AND order_runtime_status='CANCELED')
   OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders WHERE company_id=p_company_id
     AND id=v_target AND status='DRAFT')
  THEN RAISE EXCEPTION 'PROCUREMENT_OWNED_BY_OFFICE_ORDER'; END IF;
  RETURN jsonb_build_object('procurementPreserved',true,'targetSalesOrderId',v_target);
 END IF;
 RETURN private.refresh_procurement_before_cutover_retention(
  p_company_id,p_sales_id,p_actor_id,p_idempotency_key,p_action);
END $$;

CREATE FUNCTION private.sync_office_cutover_procurement(
 p_company_id uuid,p_order_id uuid,p_actor_id uuid,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_target public.backoffice_sales_orders%rowtype;v_source record;v_group record;
 v_line record;v_header public.sales_order_procurement_demands%rowtype;
 v_desired numeric;v_cap numeric;v_covered numeric;v_remaining numeric;v_alloc numeric;
 v_key uuid;v_before jsonb;v_after jsonb;v_count integer:=0;
BEGIN
 IF auth.uid() IS DISTINCT FROM p_actor_id
 OR public.private_active_company_id() IS DISTINCT FROM p_company_id OR p_operation_id IS NULL
 THEN RAISE EXCEPTION 'CUTOVER_PROCUREMENT_SYNC_CONTEXT_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text||':sales-process-cutover',0));
 SELECT document.* INTO STRICT v_target FROM public.backoffice_sales_orders document
 WHERE document.company_id=p_company_id AND document.id=p_order_id FOR UPDATE;
 FOR v_source IN SELECT DISTINCT link.source_sales_id FROM public.sales_cutover_procurement_links link
 WHERE link.company_id=p_company_id AND link.target_sales_order_id=p_order_id ORDER BY link.source_sales_id
 LOOP
  PERFORM 1 FROM public.sales_headers WHERE company_id=p_company_id AND id=v_source.source_sales_id FOR UPDATE;
  SELECT header.* INTO STRICT v_header FROM public.sales_order_procurement_demands header
  JOIN public.sales_headers source ON source.company_id=header.company_id AND source.session_id=header.cashier_session_id
  WHERE source.company_id=p_company_id AND source.id=v_source.source_sales_id FOR UPDATE OF header;
  v_key:=md5(p_operation_id::text||':'||p_order_id::text||':'||v_source.source_sales_id::text||':OFFICE_DEMAND')::uuid;
  IF EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_audit WHERE company_id=p_company_id
    AND demand_id=v_header.id AND demand_line_id IS NULL AND idempotency_key=v_key) THEN CONTINUE; END IF;
  IF v_header.stock_request_document_id IS NOT NULL THEN
   PERFORM 1 FROM public.stock_request_documents WHERE company_id=p_company_id AND id=v_header.stock_request_document_id FOR UPDATE;
   PERFORM 1 FROM public.stock_request_lines WHERE company_id=p_company_id AND document_id=v_header.stock_request_document_id ORDER BY id FOR UPDATE;
  END IF;
  PERFORM 1 FROM public.sales_order_procurement_demand_lines WHERE company_id=p_company_id
    AND demand_id=v_header.id ORDER BY id FOR UPDATE;
  v_before:=to_jsonb(v_header);
  FOR v_group IN SELECT line.stock_product_id,line.warehouse_id
   FROM public.sales_cutover_procurement_links link
   JOIN public.sales_order_procurement_demand_lines line ON line.company_id=link.company_id AND line.id=link.source_demand_line_id
   WHERE link.company_id=p_company_id AND link.target_sales_order_id=p_order_id
    AND link.source_sales_id=v_source.source_sales_id GROUP BY line.stock_product_id,line.warehouse_id
   ORDER BY line.stock_product_id,line.warehouse_id
  LOOP
   SELECT COALESCE(sum((link.source_snapshot#>>'{demandLine,demand_base_qty}')::numeric),0) INTO v_cap
   FROM public.sales_cutover_procurement_links link JOIN public.sales_order_procurement_demand_lines line
    ON line.company_id=link.company_id AND line.id=link.source_demand_line_id
   WHERE link.company_id=p_company_id AND link.target_sales_order_id=p_order_id
    AND link.source_sales_id=v_source.source_sales_id AND line.stock_product_id=v_group.stock_product_id
    AND line.warehouse_id=v_group.warehouse_id;
   SELECT COALESCE(sum(line.requested_base_qty-line.shortage_base_qty),0) INTO v_covered
   FROM public.sales_stock_reservation_lines line WHERE line.company_id=p_company_id
    AND line.sales_id=v_source.source_sales_id AND line.stock_product_id=v_group.stock_product_id
    AND line.warehouse_id=v_group.warehouse_id;
   SELECT CASE WHEN v_target.status='CANCELED' OR v_target.warehouse_id<>v_group.warehouse_id THEN 0
    ELSE LEAST(v_cap,GREATEST(COALESCE(sum(line.ordered_base_qty),0)-v_covered,0)) END INTO v_desired
   FROM public.backoffice_sales_order_lines line WHERE line.company_id=p_company_id
    AND line.sales_order_id=p_order_id AND line.product_id=v_group.stock_product_id;
   v_remaining:=v_desired;
   FOR v_line IN SELECT line.*,link.source_snapshot FROM public.sales_cutover_procurement_links link
    JOIN public.sales_order_procurement_demand_lines line ON line.company_id=link.company_id AND line.id=link.source_demand_line_id
    WHERE link.company_id=p_company_id AND link.target_sales_order_id=p_order_id
     AND link.source_sales_id=v_source.source_sales_id AND line.stock_product_id=v_group.stock_product_id
     AND line.warehouse_id=v_group.warehouse_id ORDER BY line.id
   LOOP
    IF v_line.demand_base_qty IS DISTINCT FROM (v_line.source_snapshot#>>'{demandLine,demand_base_qty}')::numeric
    THEN RAISE EXCEPTION 'CUTOVER_PROCUREMENT_ORIGINAL_CAP_DRIFT'; END IF;
    v_alloc:=LEAST(v_line.demand_base_qty,GREATEST(v_remaining,0));v_remaining:=v_remaining-v_alloc;
    UPDATE public.sales_order_procurement_demand_lines SET released_base_qty=demand_base_qty-v_alloc,
     status=CASE WHEN v_alloc=0 THEN 'CLOSED' WHEN stock_request_line_id IS NOT NULL THEN 'REQUESTED' ELSE 'OPEN' END,
     master_version=master_version+1,updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_line.id
     AND (released_base_qty IS DISTINCT FROM demand_base_qty-v_alloc OR
      status IS DISTINCT FROM CASE WHEN v_alloc=0 THEN 'CLOSED' WHEN stock_request_line_id IS NOT NULL THEN 'REQUESTED' ELSE 'OPEN' END);
   END LOOP;
  END LOOP;
  UPDATE public.sales_order_procurement_demands header SET
   total_demand_base_qty=(SELECT COALESCE(sum(demand_base_qty),0) FROM public.sales_order_procurement_demand_lines WHERE company_id=p_company_id AND demand_id=header.id),
   total_released_base_qty=(SELECT COALESCE(sum(released_base_qty),0) FROM public.sales_order_procurement_demand_lines WHERE company_id=p_company_id AND demand_id=header.id),
   status=CASE WHEN session.status='OPEN' THEN 'OPEN'
    WHEN NOT EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_lines WHERE company_id=p_company_id AND demand_id=header.id AND demand_base_qty>released_base_qty)
    THEN 'CLOSED' ELSE 'FROZEN' END,
   session_closed_at=CASE WHEN session.status='OPEN' THEN NULL ELSE COALESCE(header.session_closed_at,session.closed_at) END,
   master_version=header.master_version+1,updated_at=clock_timestamp()
  FROM public.cashier_sessions session WHERE header.company_id=p_company_id AND header.id=v_header.id
   AND session.company_id=header.company_id AND session.id=header.cashier_session_id RETURNING to_jsonb(header) INTO v_after;
  INSERT INTO public.sales_order_procurement_demand_audit(company_id,demand_id,action,idempotency_key,actor_id,before_state,after_state)
  VALUES(p_company_id,v_header.id,'QUANTITY_DELTA',v_key,p_actor_id,v_before,
   v_after||jsonb_build_object('sourceSalesId',v_source.source_sales_id,'targetSalesOrderId',p_order_id,'officeOperationId',p_operation_id));
  PERFORM private.reconcile_session_procurement_request(p_company_id,v_source.source_sales_id,p_actor_id,v_key);
  PERFORM private.sync_managed_request_single_draft_po(p_company_id,v_source.source_sales_id,p_actor_id,v_key);
  v_count:=v_count+1;
 END LOOP;
 RETURN jsonb_build_object('synchronizedSources',v_count);
END $$;

-- Wrap canonical Save/Cancel: preserve authorization, revision, reservation and DO behavior.
ALTER FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb) SET SCHEMA private;
ALTER FUNCTION private.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb) RENAME TO save_office_order_before_procurement_retention;
CREATE FUNCTION public.save_backoffice_sales_order_draft(p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_response jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':sales-process-cutover',0));
 v_response:=private.save_office_order_before_procurement_retention(p_order_id,p_expected_version,p_operation_id,p_payload);
 IF p_order_id IS NOT NULL AND NOT COALESCE((v_response->>'exactRetry')::boolean,false) THEN
  PERFORM private.sync_office_cutover_procurement(v_company,p_order_id,auth.uid(),p_operation_id);
 END IF;
 RETURN v_response;
END $$;
ALTER FUNCTION public.cancel_backoffice_sales_order(uuid,bigint,uuid,text) SET SCHEMA private;
ALTER FUNCTION private.cancel_backoffice_sales_order(uuid,bigint,uuid,text) RENAME TO cancel_office_order_before_procurement_retention;
CREATE FUNCTION public.cancel_backoffice_sales_order(p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_response jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':sales-process-cutover',0));
 v_response:=private.cancel_office_order_before_procurement_retention(p_order_id,p_expected_version,p_operation_id,p_reason);
 PERFORM private.sync_office_cutover_procurement(v_company,p_order_id,auth.uid(),p_operation_id);
 RETURN v_response;
END $$;

-- Change only the procurement classification for the verified Retail -> Office path.
ALTER FUNCTION private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)
 RENAME TO classify_cutover_before_procurement_retention;
CREATE FUNCTION private.classify_sales_process_conversion_candidate(
 p_source_mode text,p_target_mode text,p_is_final boolean,p_has_dispatch boolean,p_has_final_stock_effect boolean,
 p_has_posted_finance boolean,p_has_nonterminal_payment boolean,p_has_issued_invoice boolean,
 p_has_pending_revision boolean,p_has_open_procurement boolean
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE v_result jsonb;
BEGIN
 v_result:=private.classify_cutover_before_procurement_retention(p_source_mode,p_target_mode,p_is_final,
  p_has_dispatch,p_has_final_stock_effect,p_has_posted_finance,p_has_nonterminal_payment,
  p_has_issued_invoice,p_has_pending_revision,
  CASE WHEN p_source_mode='RETAIL_CONFIRM_INVOICE' AND p_target_mode='BACKOFFICE_DELIVERED_QTY_INVOICE' THEN false ELSE p_has_open_procurement END);
 IF p_has_open_procurement AND p_source_mode='RETAIL_CONFIRM_INVOICE'
  AND v_result->>'decision'='CONVERT' THEN
  v_result:=jsonb_set(v_result,'{requirementCodes}',v_result->'requirementCodes'||jsonb_build_array('TRANSFER_PROCUREMENT_LINEAGE'));
 END IF;
 RETURN v_result;
END $$;

-- Exact, audited runtime edits; fail rather than patch an unknown call chain.
DO $patch$
DECLARE v_definition text;v_marker text;v_replacement text;
BEGIN
 v_definition:=pg_get_functiondef('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'::regprocedure);
 v_marker:=$m$    OR EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_lines demand
      WHERE demand.company_id=p_company_id AND demand.sales_id=v_source.id
        AND demand.status IN('OPEN','REQUESTED','ORDERED','AMENDMENT_REQUIRED'))
$m$;
 IF position(v_marker IN v_definition)=0 OR position('v_cancel:=public.cancel_pos_sales_order' IN v_definition)=0 THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical converter procurement/cancel chain drift';
 END IF;
 v_definition:=replace(v_definition,v_marker,'');
 v_marker:=$m$    v_cancel:=public.cancel_pos_sales_order(v_source.id,v_source.master_version,
      gen_random_uuid(),v_reason);$m$;
 v_replacement:=$m$    PERFORM private.link_sales_cutover_procurement(p_company_id,v_source.id,v_target_id,p_actor_id,p_operation_id);
    PERFORM set_config('kgs.cutover_procurement_target',v_target_id::text,true);
    v_cancel:=public.cancel_pos_sales_order(v_source.id,v_source.master_version,
      gen_random_uuid(),v_reason);
    PERFORM set_config('kgs.cutover_procurement_target','',true);
    IF EXISTS(SELECT 1 FROM public.sales_cutover_procurement_links link
      JOIN public.sales_order_procurement_demand_lines demand ON demand.company_id=link.company_id AND demand.id=link.source_demand_line_id
      LEFT JOIN public.stock_request_lines request_line ON request_line.company_id=demand.company_id AND request_line.id=demand.stock_request_line_id
      LEFT JOIN public.stock_request_documents request_document ON request_document.company_id=request_line.company_id AND request_document.id=request_line.document_id
      WHERE link.company_id=p_company_id AND link.target_sales_order_id=v_target_id
        AND (link.source_snapshot->'demandLine' IS DISTINCT FROM to_jsonb(demand)
          OR link.source_snapshot->'stockRequestLine' IS DISTINCT FROM to_jsonb(request_line)
          OR link.source_snapshot->'stockRequest' IS DISTINCT FROM to_jsonb(request_document)))
    THEN RAISE EXCEPTION 'CUTOVER_PROCUREMENT_PRESERVATION_FAILED'; END IF;$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact converter cancel call drift'; END IF;
 EXECUTE replace(v_definition,v_marker,v_replacement);

 v_definition:=pg_get_functiondef('private.get_purchase_daily_replenishment_candidates_core(uuid,date)'::regprocedure);
 v_marker:=$m$    LEFT JOIN public.sales_order_procurement_demand_lines demand_line
      ON demand_line.company_id=request_line.company_id
     AND demand_line.stock_request_line_id=request_line.id$m$;
 v_replacement:=$m$    LEFT JOIN LATERAL (
      SELECT CASE WHEN count(DISTINCT demand.warehouse_id)=1
        THEN min(demand.warehouse_id::text)::uuid ELSE NULL END warehouse_id
      FROM public.sales_order_procurement_demand_lines demand
      WHERE demand.company_id=request_line.company_id
        AND demand.stock_request_line_id=request_line.id
    ) demand_line ON true$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: shared request coverage chain drift'; END IF;
 EXECUTE replace(v_definition,v_marker,v_replacement);
END $patch$;

DO $acl$
DECLARE v_signature text;
BEGIN
 FOREACH v_signature IN ARRAY ARRAY[
 'private.refresh_sales_order_procurement_demand(uuid,uuid,uuid,uuid,text)',
 'private.refresh_procurement_before_cutover_retention(uuid,uuid,uuid,uuid,text)',
 'private.sync_office_cutover_procurement(uuid,uuid,uuid,uuid)',
 'private.save_office_order_before_procurement_retention(uuid,bigint,uuid,jsonb)',
 'private.cancel_office_order_before_procurement_retention(uuid,bigint,uuid,text)',
 'private.classify_cutover_before_procurement_retention(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)',
 'private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)']
 LOOP EXECUTE 'REVOKE ALL ON FUNCTION '||v_signature||' FROM PUBLIC,anon,authenticated';
 EXECUTE 'GRANT EXECUTE ON FUNCTION '||v_signature||' TO service_role'; END LOOP;
END $acl$;
REVOKE ALL ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb),public.cancel_backoffice_sales_order(uuid,bigint,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb),public.cancel_backoffice_sales_order(uuid,bigint,uuid,text) TO authenticated,service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes) VALUES('20260915141000','sales_cutover_procurement_retention_runtime',
 'Preserve existing procurement through Retail cancellation; bounded Office lifecycle synchronization; shared request coverage counted once. No live backfill.');

$release_20260915141000$;
 END IF;
END $install_20260915141000$;
DO $install_20260915142000$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915142000') THEN
 EXECUTE $release_20260915142000$
-- Pre-dispatch delta only: same SO/Reservation/DO identities, canonical pricing/stock.
-- No existing-row backfill. No Stock/FIFO/payment/session/Finance posting.

DO $guard$
BEGIN
 IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915142000') THEN RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260915142000'; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915141000')
 OR to_regprocedure('private.recompose_office_pre_dispatch_fulfillment(uuid,uuid)') IS NOT NULL
 OR to_regprocedure('private.validate_office_untouched_fulfillment(uuid,uuid)') IS NOT NULL
 OR to_regprocedure('private.save_office_order_before_pre_dispatch_delta(uuid,bigint,uuid,jsonb)') IS NOT NULL
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: pre-dispatch delta dependency/collision'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
 OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance/offline queue'; END IF;
END $guard$;

CREATE FUNCTION private.validate_office_untouched_fulfillment(p_company_id uuid,p_order_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_order public.backoffice_sales_orders%rowtype;
 v_reservation public.backoffice_sales_reservations%rowtype;v_delivery public.backoffice_sales_delivery_orders%rowtype;
BEGIN
 IF auth.uid() IS NULL OR public.private_active_company_id() IS DISTINCT FROM p_company_id THEN
  RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_CONTEXT_INVALID'; END IF;
 SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders WHERE company_id=p_company_id AND id=p_order_id FOR UPDATE;
 PERFORM 1 FROM public.backoffice_sales_reservations WHERE company_id=p_company_id AND sales_order_id=p_order_id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.backoffice_sales_delivery_orders WHERE company_id=p_company_id AND sales_order_id=p_order_id ORDER BY id FOR UPDATE;
 IF v_order.status<>'CONFIRMED' OR v_order.fulfillment_status NOT IN('CONFIRMED','PREPARING')
 OR (SELECT count(*) FROM public.backoffice_sales_reservations WHERE company_id=p_company_id AND sales_order_id=p_order_id)<>1
 OR (SELECT count(*) FROM public.backoffice_sales_delivery_orders WHERE company_id=p_company_id AND sales_order_id=p_order_id)<>1 THEN
  RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_FULFILLMENT_STATE_INVALID'; END IF;
 SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations WHERE company_id=p_company_id AND sales_order_id=p_order_id;
 SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders WHERE company_id=p_company_id AND sales_order_id=p_order_id;
 IF v_reservation.status NOT IN('OPEN','PARTIALLY_ALLOCATED','ALLOCATED')
 OR v_reservation.total_released_base_qty<>0 OR v_reservation.total_in_transit_base_qty<>0
 OR v_reservation.total_completed_base_qty<>0 OR v_delivery.delivery_kind<>'INITIAL'
 OR v_delivery.status NOT IN('PREPARING','READY') OR v_delivery.total_shipped_base_qty<>0
 OR v_delivery.total_received_base_qty<>0 OR v_delivery.reservation_id<>v_reservation.id
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_dispatches WHERE company_id=p_company_id AND delivery_order_id=v_delivery.id)
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_receipt_lines WHERE company_id=p_company_id AND sales_order_id=p_order_id)
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines WHERE company_id=p_company_id AND sales_order_id=p_order_id)
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines WHERE company_id=p_company_id AND sales_order_id=p_order_id)
 THEN RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_DEPENDENCY_REQUIRES_CORRECTION'; END IF;
 PERFORM 1 FROM public.backoffice_sales_reservation_lines WHERE company_id=p_company_id AND reservation_id=v_reservation.id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.backoffice_sales_delivery_order_lines WHERE company_id=p_company_id AND delivery_order_id=v_delivery.id ORDER BY id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.backoffice_sales_reservation_lines WHERE company_id=p_company_id AND reservation_id=v_reservation.id
   AND (released_base_qty<>0 OR in_transit_base_qty<>0 OR completed_base_qty<>0))
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_order_lines WHERE company_id=p_company_id AND delivery_order_id=v_delivery.id
   AND (shipped_base_qty<>0 OR received_base_qty<>0))
 THEN RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_DEPENDENCY_REQUIRES_CORRECTION'; END IF;
END $$;

CREATE OR REPLACE FUNCTION private.recompose_office_pre_dispatch_fulfillment(p_order_id uuid, p_confirm_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_order public.backoffice_sales_orders%rowtype;v_reservation uuid:=(SELECT id FROM public.backoffice_sales_reservations WHERE company_id=v_company AND sales_order_id=p_order_id);
  v_delivery uuid:=(SELECT id FROM public.backoffice_sales_delivery_orders WHERE company_id=v_company AND sales_order_id=p_order_id AND delivery_kind='INITIAL');v_delivery_audit_operation uuid:=gen_random_uuid();
  v_delivery_no text;v_now timestamptz:=clock_timestamp();v_warehouse_negative boolean;
  v_total numeric(24,6);v_shortage_total numeric(24,6):=0;v_line_count integer;
  v_product record;v_requirement record;v_on_hand numeric(24,6);
  v_pos_reserved numeric(24,6);v_backoffice_reserved numeric(24,6);
  v_available numeric(24,6);v_available_remaining numeric(24,6);
  v_line_available numeric(24,6);v_availability jsonb:='{}'::jsonb;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT document.* INTO v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND'; END IF;
  IF v_order.status<>'CONFIRMED' OR v_order.fulfillment_status NOT IN('CONFIRMED','PREPARING')
    OR v_order.sales_origin<>'BACKOFFICE_SALES'
    OR v_order.sales_process_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_CONFIRM_FULFILLMENT_STATE_INVALID';
  END IF;
  IF NULLIF(current_setting('kgs.office_pre_dispatch_revision_order',true),'') IS DISTINCT FROM p_order_id::text
    OR v_reservation IS NULL OR v_delivery IS NULL
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_reservation_lines WHERE company_id=v_company AND reservation_id=v_reservation)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_order_lines WHERE company_id=v_company AND delivery_order_id=v_delivery) THEN
    RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_RECOMPOSE_CONTEXT_INVALID';
  END IF;
  SELECT warehouse.allow_negative_stock INTO v_warehouse_negative
  FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
    AND warehouse.id=v_order.warehouse_id AND warehouse.is_active
    AND warehouse.is_sale_source FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_WAREHOUSE_SCOPE_INVALID'; END IF;

  PERFORM 1 FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=p_order_id FOR SHARE;
  SELECT count(*),sum(requirement.quantity_base) INTO v_line_count,v_total
  FROM private.backoffice_sales_stock_requirements(v_company,p_order_id) requirement;
  IF v_line_count=0 OR v_total IS NULL OR v_total<=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_STOCK_REQUIREMENT_MISSING';
  END IF;

  FOR v_product IN
    SELECT requirement.stock_product_id,sum(requirement.quantity_base) requested_base_qty
    FROM private.backoffice_sales_stock_requirements(v_company,p_order_id) requirement
    GROUP BY requirement.stock_product_id ORDER BY requirement.stock_product_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(
      v_company::text||':'||v_order.warehouse_id::text||':'||v_product.stock_product_id::text,0));
    SELECT stock.stock_qty INTO v_on_hand FROM public.product_stocks stock
    WHERE stock.company_id=v_company AND stock.warehouse_id=v_order.warehouse_id
      AND stock.product_id=v_product.stock_product_id FOR UPDATE;
    v_on_hand:=COALESCE(v_on_hand,0);
    SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-line.dispatched_base_qty),0)
      INTO v_pos_reserved
    FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company AND line.warehouse_id=v_order.warehouse_id
      AND line.stock_product_id=v_product.stock_product_id
      AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED');
    SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-
      line.in_transit_base_qty-line.completed_base_qty),0) INTO v_backoffice_reserved
    FROM public.backoffice_sales_reservation_lines line
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company AND line.warehouse_id=v_order.warehouse_id
      AND line.product_id=v_product.stock_product_id
      AND reservation.status<>'RELEASED';
    v_available:=v_on_hand-v_pos_reserved-v_backoffice_reserved;
    IF v_product.requested_base_qty>GREATEST(v_available,0) AND NOT v_warehouse_negative THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_NEGATIVE_RESERVATION_REQUIRES_WAREHOUSE_OPT_IN';
    END IF;
    v_shortage_total:=v_shortage_total+
      GREATEST(v_product.requested_base_qty-GREATEST(v_available,0),0);
    v_availability:=v_availability||jsonb_build_object(
      v_product.stock_product_id::text,GREATEST(v_available,0));
  END LOOP;

  UPDATE public.backoffice_sales_reservations SET warehouse_id=v_order.warehouse_id,
    total_ordered_base_qty=v_total,total_reserved_base_qty=v_total,shortage_base_qty=v_shortage_total,
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_reservation;

  FOR v_requirement IN
    SELECT requirement.* FROM private.backoffice_sales_stock_requirements(v_company,p_order_id) requirement
    ORDER BY requirement.stock_product_id,requirement.sales_order_line_id,
      requirement.bundle_component_line_no NULLS FIRST
  LOOP
    v_available_remaining:=COALESCE((v_availability->>v_requirement.stock_product_id::text)::numeric,0);
    v_line_available:=LEAST(v_requirement.quantity_base,v_available_remaining);
    v_availability:=jsonb_set(v_availability,ARRAY[v_requirement.stock_product_id::text],
      to_jsonb(v_available_remaining-v_line_available),true);
    INSERT INTO public.backoffice_sales_reservation_lines(
      company_id,reservation_id,sales_order_id,sales_order_line_id,product_id,
      warehouse_id,ordered_base_qty,reserved_base_qty,stock_uom_id,
      stock_uom_name_snapshot,quantity_uom,factor_to_base,
      available_base_qty_snapshot,shortage_base_qty,bundle_component_line_no)
    VALUES(v_company,v_reservation,p_order_id,v_requirement.sales_order_line_id,
      v_requirement.stock_product_id,v_order.warehouse_id,v_requirement.quantity_base,
      v_requirement.quantity_base,v_requirement.stock_uom_id,v_requirement.stock_uom_name,
      v_requirement.quantity_uom,v_requirement.factor_to_base,v_line_available,
      v_requirement.quantity_base-v_line_available,v_requirement.bundle_component_line_no);
  END LOOP;

  UPDATE public.backoffice_sales_delivery_orders SET scheduled_date=v_order.planned_delivery_date,
    recipient_snapshot=v_order.customer_snapshot,total_planned_base_qty=v_total,
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_delivery RETURNING delivery_no INTO v_delivery_no;

  INSERT INTO public.backoffice_sales_delivery_order_lines(
    company_id,delivery_order_id,sales_order_id,reservation_id,reservation_line_id,
    sales_order_line_id,line_no,product_id,uom_id,product_code_snapshot,
    product_name_snapshot,uom_code_snapshot,uom_name_snapshot,base_qty_per_uom,
    planned_qty_uom,planned_base_qty)
  SELECT v_company,v_delivery,p_order_id,v_reservation,reservation_line.id,
    reservation_line.sales_order_line_id,
    row_number() OVER(ORDER BY order_line.line_no,
      reservation_line.bundle_component_line_no NULLS FIRST,reservation_line.id)::integer,
    reservation_line.product_id,reservation_line.stock_uom_id,product.sku,product.name,
    uom.code,reservation_line.stock_uom_name_snapshot,reservation_line.factor_to_base,
    reservation_line.quantity_uom,reservation_line.ordered_base_qty
  FROM public.backoffice_sales_reservation_lines reservation_line
  JOIN public.backoffice_sales_order_lines order_line
    ON order_line.company_id=reservation_line.company_id
   AND order_line.id=reservation_line.sales_order_line_id
  JOIN public.products product ON product.company_id=reservation_line.company_id
    AND product.id=reservation_line.product_id
  JOIN public.uoms uom ON uom.company_id=reservation_line.company_id
    AND uom.id=reservation_line.stock_uom_id
  WHERE reservation_line.company_id=v_company
    AND reservation_line.reservation_id=v_reservation;

  INSERT INTO public.backoffice_sales_fulfillment_audit(
    company_id,sales_order_id,reservation_id,operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(v_company,p_order_id,v_reservation,p_confirm_operation_id,'UPDATE_PLAN',v_actor,
    'Revisi SO sebelum pengiriman',
    current_setting('kgs.office_revision_before_reservation',true)::jsonb,
    jsonb_build_object('header',(SELECT to_jsonb(header) FROM public.backoffice_sales_reservations header WHERE id=v_reservation),
      'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line WHERE company_id=v_company AND reservation_id=v_reservation)));
  INSERT INTO public.backoffice_sales_fulfillment_audit(
    company_id,sales_order_id,delivery_order_id,operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(v_company,p_order_id,v_delivery,v_delivery_audit_operation,'UPDATE_PLAN',v_actor,
    'Revisi SO sebelum pengiriman',
    current_setting('kgs.office_revision_before_delivery',true)::jsonb,
    jsonb_build_object('header',(SELECT to_jsonb(header) FROM public.backoffice_sales_delivery_orders header WHERE id=v_delivery),
      'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_delivery_order_lines line WHERE company_id=v_company AND delivery_order_id=v_delivery)));
  UPDATE public.backoffice_sales_orders SET fulfillment_status='PREPARING',
    updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=p_order_id;
  RETURN jsonb_build_object('reservationId',v_reservation,'deliveryOrderId',v_delivery,
    'deliveryNo',v_delivery_no,'deliveryStatus','READY','reservedBaseQty',v_total,
    'shortageBaseQty',v_shortage_total,'requirementLineCount',v_line_count);
END
$function$;


ALTER FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
 RENAME TO save_office_order_before_pre_dispatch_delta;
ALTER FUNCTION public.save_office_order_before_pre_dispatch_delta(uuid,bigint,uuid,jsonb) SET SCHEMA private;
CREATE FUNCTION public.save_backoffice_sales_order_draft(p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_order public.backoffice_sales_orders%rowtype;
 v_response jsonb;v_retry jsonb;v_hash text;
BEGIN
 PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders',
  CASE WHEN p_order_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':sales-process-cutover',0));
 IF p_operation_id IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PAYLOAD_INVALID'; END IF;
 v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('orderId',p_order_id,
  'expectedVersion',p_expected_version,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
 v_retry:=private.backoffice_operation_retry(v_company,p_operation_id,'SAVE_DRAFT',v_hash);
 IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
 SELECT * INTO v_order FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=p_order_id FOR UPDATE;
 IF v_order.status='CONFIRMED' AND EXISTS(SELECT 1 FROM public.backoffice_sales_reservations WHERE company_id=v_company AND sales_order_id=p_order_id) THEN
  IF v_order.master_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  PERFORM private.validate_office_untouched_fulfillment(v_company,p_order_id);
  PERFORM set_config('kgs.office_revision_before_reservation',(SELECT jsonb_build_object(
   'header',to_jsonb(header),'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line
    WHERE line.company_id=v_company AND line.reservation_id=header.id))::text
   FROM public.backoffice_sales_reservations header WHERE company_id=v_company AND sales_order_id=p_order_id),true);
  PERFORM set_config('kgs.office_revision_before_delivery',(SELECT jsonb_build_object(
   'header',to_jsonb(header),'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_delivery_order_lines line
    WHERE line.company_id=v_company AND line.delivery_order_id=header.id))::text
   FROM public.backoffice_sales_delivery_orders header WHERE company_id=v_company AND sales_order_id=p_order_id),true);
  -- Only unconsumed mutable lines; snapshots are captured above and audited by recompose.
  DELETE FROM public.backoffice_sales_delivery_order_lines WHERE company_id=v_company AND sales_order_id=p_order_id;
  DELETE FROM public.backoffice_sales_reservation_lines WHERE company_id=v_company AND sales_order_id=p_order_id;
  PERFORM set_config('kgs.office_pre_dispatch_revision_order',p_order_id::text,true);
 END IF;
 v_response:=private.save_office_order_before_pre_dispatch_delta(p_order_id,p_expected_version,p_operation_id,p_payload);
 PERFORM set_config('kgs.office_pre_dispatch_revision_order','',true);
 PERFORM set_config('kgs.office_revision_before_reservation','',true);
 PERFORM set_config('kgs.office_revision_before_delivery','',true);
 RETURN v_response;
END $$;

CREATE FUNCTION private.release_office_untouched_fulfillment(p_company_id uuid,p_order_id uuid,p_operation_id uuid,p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_reservation public.backoffice_sales_reservations%rowtype;v_delivery public.backoffice_sales_delivery_orders%rowtype;
 v_before jsonb;v_after jsonb;v_actor uuid:=auth.uid();v_now timestamptz:=clock_timestamp();
BEGIN
 PERFORM private.validate_office_untouched_fulfillment(p_company_id,p_order_id);
 SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations WHERE company_id=p_company_id AND sales_order_id=p_order_id;
 SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders WHERE company_id=p_company_id AND sales_order_id=p_order_id;
 v_before:=jsonb_build_object('header',to_jsonb(v_reservation),'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line WHERE company_id=p_company_id AND reservation_id=v_reservation.id));
 UPDATE public.backoffice_sales_reservation_lines SET released_base_qty=reserved_base_qty,updated_at=v_now WHERE company_id=p_company_id AND reservation_id=v_reservation.id;
 UPDATE public.backoffice_sales_reservations SET status='RELEASED',total_released_base_qty=total_reserved_base_qty,
  released_by=v_actor,released_at=v_now,release_reason=p_reason,master_version=master_version+1,updated_by=v_actor,updated_at=v_now WHERE company_id=p_company_id AND id=v_reservation.id;
 v_after:=jsonb_build_object('header',(SELECT to_jsonb(header) FROM public.backoffice_sales_reservations header WHERE id=v_reservation.id),
  'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line WHERE company_id=p_company_id AND reservation_id=v_reservation.id));
 INSERT INTO public.backoffice_sales_fulfillment_audit(company_id,sales_order_id,reservation_id,operation_id,action,actor_id,reason,before_state,after_state)
 VALUES(p_company_id,p_order_id,v_reservation.id,md5(p_operation_id::text||':RELEASE')::uuid,'RELEASE',v_actor,p_reason,v_before,v_after);
 UPDATE public.backoffice_sales_delivery_orders document SET status='CANCELED',canceled_by=v_actor,canceled_at=v_now,cancel_reason=p_reason,
  master_version=document.master_version+1,updated_by=v_actor,updated_at=v_now WHERE document.company_id=p_company_id AND document.id=v_delivery.id RETURNING to_jsonb(document) INTO v_after;
 INSERT INTO public.backoffice_sales_fulfillment_audit(company_id,sales_order_id,delivery_order_id,operation_id,action,actor_id,reason,before_state,after_state)
 VALUES(p_company_id,p_order_id,v_delivery.id,md5(p_operation_id::text||':CANCEL_DO')::uuid,'CANCEL',v_actor,p_reason,to_jsonb(v_delivery),v_after);
END $$;

DO $patch$
DECLARE v_definition text;v_marker text;
BEGIN
 v_definition:=pg_get_functiondef('public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure);
 v_marker:=$m$IF v_document.status='CONFIRMED' AND v_document.fulfillment_status<>'CONFIRMED' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC'; END IF;$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: core revision guard drift'; END IF;
 v_definition:=replace(v_definition,v_marker,$m$IF v_document.status='CONFIRMED' AND v_document.fulfillment_status<>'CONFIRMED'
  AND NOT (v_document.fulfillment_status='PREPARING'
   AND NULLIF(current_setting('kgs.office_pre_dispatch_revision_order',true),'')=v_document.id::text)
 THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC'; END IF;$m$);
 v_marker:=$m$v_after:=private.backoffice_sales_order_snapshot(v_company,v_document.id);$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: core snapshot boundary drift'; END IF;
 v_definition:=replace(v_definition,v_marker,$m$IF NULLIF(current_setting('kgs.office_pre_dispatch_revision_order',true),'')=v_document.id::text THEN
  PERFORM private.recompose_office_pre_dispatch_fulfillment(v_document.id,p_operation_id);
 END IF;
 v_after:=private.backoffice_sales_order_snapshot(v_company,v_document.id);$m$);
 EXECUTE v_definition;
 v_definition:=pg_get_functiondef('private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)'::regprocedure);
 v_marker:=$m$IF NOT (v_document.status IN('DRAFT','SENT') OR (v_document.status='CONFIRMED' AND v_document.fulfillment_status='CONFIRMED')) THEN RAISE EXCEPTION 'BACKOFFICE_SALES_CANCEL_STATE_INVALID'; END IF;$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Cancel guard drift'; END IF;
 v_definition:=replace(v_definition,v_marker,$m$IF v_document.status='CONFIRMED' AND EXISTS(SELECT 1 FROM public.backoffice_sales_reservations WHERE company_id=v_company AND sales_order_id=p_order_id) THEN
  IF nullif(btrim(COALESCE(p_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
  PERFORM private.release_office_untouched_fulfillment(v_company,p_order_id,p_operation_id,btrim(p_reason));
 ELSIF NOT (v_document.status IN('DRAFT','SENT') OR (v_document.status='CONFIRMED' AND v_document.fulfillment_status='CONFIRMED')) THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_CANCEL_STATE_INVALID'; END IF;$m$);
 EXECUTE v_definition;
END $patch$;
DO $acl$
DECLARE v_signature text;
BEGIN
 FOREACH v_signature IN ARRAY ARRAY[
 'private.validate_office_untouched_fulfillment(uuid,uuid)',
 'private.recompose_office_pre_dispatch_fulfillment(uuid,uuid)',
 'private.release_office_untouched_fulfillment(uuid,uuid,uuid,text)',
 'private.save_office_order_before_pre_dispatch_delta(uuid,bigint,uuid,jsonb)']
 LOOP EXECUTE 'REVOKE ALL ON FUNCTION '||v_signature||' FROM PUBLIC,anon,authenticated';
 EXECUTE 'GRANT EXECUTE ON FUNCTION '||v_signature||' TO service_role'; END LOOP;
END $acl$;
REVOKE ALL ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb) TO authenticated,service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes) VALUES('20260915142000','office_pre_dispatch_fulfillment_delta',
 'Same-number public SO revision/cancel before dispatch; canonical stock computation, existing parent IDs, immutable full fulfillment snapshots; no backfill/final effects.');
NOTIFY pgrst,'reload schema';

$release_20260915142000$;
 END IF;
END $install_20260915142000$;
DO $install_20260916100000$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916100000') THEN
 EXECUTE $release_20260916100000$
-- Additive NULL representation fix. No data mutation/backfill.

DO $guard$
DECLARE v_definition text;v_old text;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915142000')
 OR EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916100000')
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: absent-request fix ledger'; END IF;
 v_definition:=pg_get_functiondef('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)'::regprocedure);
 FOREACH v_old IN ARRAY ARRAY['to_jsonb(request_line)','to_jsonb(request_document)'] LOOP
  IF position('IS DISTINCT FROM '||v_old IN v_definition)=0 THEN
   RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: preservation NULL marker drift'; END IF;
  v_definition:=replace(v_definition,'IS DISTINCT FROM '||v_old,
   'IS DISTINCT FROM COALESCE('||v_old||',''null''::jsonb)');
 END LOOP;
 EXECUTE v_definition;
END $guard$;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260916100000','cutover_absent_request_snapshot_fix',
 'Represent absent request LEFT JOIN rows as JSON null; preserve whole-row comparisons. No backfill.');
NOTIFY pgrst,'reload schema';

$release_20260916100000$;
 END IF;
END $install_20260916100000$;
DO $install_20260916101000$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916101000') THEN
 EXECUTE $release_20260916101000$
-- Explicit recovery of historical procurement-only KEPT Retail items.
-- No automatic backfill; historical plan/item/KEEP_ITEM audit are untouched.

DO $guard$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916100000')
 OR EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916101000')
 OR to_regprocedure('public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid)') IS NOT NULL
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained recovery dependency/collision'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
 OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance/offline operations'; END IF;
END $guard$;

CREATE FUNCTION public.recover_retained_sales_process_order(p_item_id uuid,
 p_expected_plan_version bigint,p_expected_source_version bigint,
 p_expected_settings_version bigint,p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
 v_item public.sales_process_cutover_items%rowtype;v_plan public.sales_process_cutover_plans%rowtype;
 v_setting public.company_sales_process_settings%rowtype;v_audit public.sales_process_cutover_audit%rowtype;
 v_hash text;v_result jsonb;v_source public.sales_headers%rowtype;v_scope text;
BEGIN
 IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_actor AND role::text='super_admin')
 THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED'; END IF;
 IF p_item_id IS NULL OR p_operation_id IS NULL OR p_expected_plan_version IS NULL
 OR p_expected_source_version IS NULL OR p_expected_settings_version IS NULL
 THEN RAISE EXCEPTION 'SALES_PROCESS_RECOVERY_REQUEST_INVALID'; END IF;
 v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('itemId',p_item_id,
 'planVersion',p_expected_plan_version,'sourceVersion',p_expected_source_version,
 'settingsVersion',p_expected_settings_version,'actorId',v_actor)::text,'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':sales-process-cutover',0));
 SELECT * INTO v_audit FROM public.sales_process_cutover_audit WHERE company_id=v_company
  AND action='APPLY_ITEM' AND operation_id=p_operation_id LIMIT 1;
 IF FOUND THEN
  IF v_audit.after_state->>'recoveryRequestHash' IS DISTINCT FROM v_hash
  THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT'; END IF;
  RETURN v_audit.after_state->'converterResult'||jsonb_build_object('exactRetry',true);
 END IF;
 SELECT * INTO v_item FROM public.sales_process_cutover_items
 WHERE company_id=v_company AND id=p_item_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_RECOVERY_ITEM_NOT_FOUND'; END IF;
 SELECT * INTO STRICT v_plan FROM public.sales_process_cutover_plans
 WHERE company_id=v_company AND id=v_item.cutover_plan_id FOR UPDATE;
 SELECT * INTO STRICT v_setting FROM public.company_sales_process_settings
 WHERE company_id=v_company FOR UPDATE;
 IF v_plan.master_version<>p_expected_plan_version
 THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_PLAN_VERSION_STALE'; END IF;
 IF v_setting.master_version<>p_expected_settings_version
 THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_STALE'; END IF;
 IF v_setting.active_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE' OR v_plan.status<>'APPLIED'
 OR v_plan.target_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE' OR v_item.item_status<>'KEPT'
 OR v_item.source_document_type<>'RETAIL_SALE' OR v_item.target_document_id IS NOT NULL
 OR v_item.blocker_codes<>'["OPEN_PROCUREMENT_MUST_FINISH"]'::jsonb
 OR NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_audit WHERE company_id=v_company
  AND cutover_plan_id=v_plan.id AND cutover_item_id=v_item.id AND action='KEEP_ITEM')
 THEN RAISE EXCEPTION 'SALES_PROCESS_RECOVERY_ITEM_NOT_ELIGIBLE'; END IF;
 IF EXISTS(SELECT 1 FROM public.sales_process_cutover_audit WHERE company_id=v_company
  AND cutover_item_id=v_item.id AND action='APPLY_ITEM')
 THEN RAISE EXCEPTION 'SALES_PROCESS_RECOVERY_ALREADY_APPLIED'; END IF;
 IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans WHERE company_id=v_company
  AND status IN('DRAFT','PREVIEWED','APPLYING'))
 OR EXISTS(SELECT 1 FROM public.finance_posting_queue_runs WHERE company_id=v_company
  AND status IN('PREVIEWED','APPROVED','PROCESSING'))
 OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions WHERE company_id=v_company
  AND status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
 THEN RAISE EXCEPTION 'SALES_PROCESS_RECOVERY_ACTIVE_OPERATION'; END IF;
 SELECT * INTO v_source FROM public.sales_headers WHERE company_id=v_company
 AND id=v_item.source_document_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'SALES_PROCESS_RECOVERY_SOURCE_NOT_FOUND'; END IF;
 IF v_source.master_version<>p_expected_source_version
 THEN RAISE EXCEPTION 'SALES_PROCESS_RECOVERY_SOURCE_VERSION_STALE'; END IF;
 v_scope:=current_setting('kgs.sales_process_cutover_mutation',true);
 PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
 v_result:=private.convert_retail_sale_to_backoffice_order(v_company,v_source.id,v_actor,p_operation_id);
 PERFORM set_config('kgs.sales_process_cutover_mutation',COALESCE(v_scope,''),true);
 IF NOT COALESCE((v_result->>'sourceClosed')::boolean,false)
 OR v_result->>'targetDocumentType'<>'BACKOFFICE_SALES_ORDER'
 THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_CONVERTER_RESULT_INVALID'; END IF;
 INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,cutover_item_id,
 action,actor_id,operation_id,before_state,after_state)
 VALUES(v_company,v_plan.id,v_item.id,'APPLY_ITEM',v_actor,p_operation_id,to_jsonb(v_item),
 jsonb_build_object('recovery',true,'recoveryRequestHash',v_hash,
 'sourceVersion',p_expected_source_version,'converterResult',v_result));
 RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid) TO authenticated,service_role;

ALTER FUNCTION private.get_sales_process_cutover_plan_core(uuid,uuid)
RENAME TO get_cutover_plan_before_retained_recovery;
CREATE FUNCTION private.get_sales_process_cutover_plan_core(p_company_id uuid,p_plan_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
SET statement_timeout='8s' AS $$
DECLARE v_result jsonb;v_items jsonb;
BEGIN
 v_result:=private.get_cutover_plan_before_retained_recovery(p_company_id,p_plan_id);
 SELECT COALESCE(jsonb_agg(item.value||CASE WHEN audit.id IS NULL THEN '{}'::jsonb ELSE
 jsonb_build_object('recovered',true,'recoveredAt',audit.created_at,
 'targetDocumentId',audit.after_state->'converterResult'->>'targetDocumentId',
 'targetDocumentType',audit.after_state->'converterResult'->>'targetDocumentType',
 'targetDocumentNo',audit.after_state->'converterResult'->>'targetDocumentNo') END ORDER BY item.ordinality),'[]'::jsonb)
 INTO v_items FROM jsonb_array_elements(v_result->'items') WITH ORDINALITY item(value,ordinality)
 LEFT JOIN public.sales_process_cutover_audit audit ON audit.company_id=p_company_id
 AND audit.cutover_plan_id=p_plan_id AND audit.cutover_item_id=(item.value->>'itemId')::uuid
 AND audit.action='APPLY_ITEM' AND audit.after_state->>'recovery'='true';
 RETURN jsonb_set(v_result,'{items}',v_items);
END $$;
REVOKE ALL ON FUNCTION private.get_sales_process_cutover_plan_core(uuid,uuid),
 private.get_cutover_plan_before_retained_recovery(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.get_sales_process_cutover_plan_core(uuid,uuid),
 private.get_cutover_plan_before_retained_recovery(uuid,uuid) TO service_role;

-- Actual preview wrapper already has per-candidate blockers and counter rebuild.
DO $patch$
DECLARE v_definition text;v_marker text;
BEGIN
 v_definition:=pg_get_functiondef('private.get_sales_process_cutover_preview_core(uuid,text)'::regprocedure);
 v_marker:=$m$      IF NOT v_document.is_tempo AND v_document.order_date>v_today THEN$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: reverse preview marker drift'; END IF;
 v_definition:=replace(v_definition,v_marker,$m$      IF EXISTS(SELECT 1 FROM public.sales_cutover_procurement_links link
        JOIN public.sales_order_procurement_demand_lines demand ON demand.company_id=link.company_id AND demand.id=link.source_demand_line_id
        WHERE link.company_id=p_company_id AND link.target_sales_order_id=v_document.id
        AND demand.demand_base_qty> demand.released_base_qty)
        AND NOT (v_blockers ? 'OPEN_PROCUREMENT_MUST_FINISH') THEN
        v_blockers:=v_blockers||jsonb_build_array('OPEN_PROCUREMENT_MUST_FINISH');
      END IF;
$m$||v_marker);
 EXECUTE v_definition;
 v_definition:=pg_get_functiondef('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)'::regprocedure);
 v_marker:=$m$  IF v_source.sales_origin<>'BACKOFFICE_SALES'$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: reverse converter marker drift'; END IF;
 EXECUTE replace(v_definition,v_marker,$m$  IF EXISTS(SELECT 1 FROM public.sales_cutover_procurement_links link
    JOIN public.sales_order_procurement_demand_lines demand ON demand.company_id=link.company_id AND demand.id=link.source_demand_line_id
    WHERE link.company_id=p_company_id AND link.target_sales_order_id=v_source.id
    AND demand.demand_base_qty> demand.released_base_qty) THEN
    RAISE EXCEPTION 'OPEN_PROCUREMENT_MUST_FINISH'; END IF;
$m$||v_marker);
END $patch$;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260916101000','retained_order_recovery',
 'Explicit Super Admin recovery appends APPLY_ITEM, leaves historical KEPT state untouched; read projection and linked reverse ownership guard. No backfill.');
NOTIFY pgrst,'reload schema';

$release_20260916101000$;
 END IF;
END $install_20260916101000$;
DO $install_20260916102000$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916102000') THEN
 EXECUTE $release_20260916102000$
-- Existing settings and Sales document-log readers; no new tabs/templates.

DO $guard$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916101000')
 OR EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260916102000')
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained reader dependency/collision'; END IF;
END $guard$;
CREATE FUNCTION public.get_retained_sales_process_recovery_candidates()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND role::text='super_admin')
 THEN RAISE EXCEPTION 'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('itemId',item.id,'planId',plan.id,
 'planVersion',plan.master_version,'sourceDocumentId',source.id,
 'sourceDocumentNo',item.source_document_no,'sourceVersion',source.master_version,
 'sourceStatus',source.order_runtime_status,'settingsVersion',setting.master_version)
 ORDER BY plan.created_at,item.source_document_no,item.id)
 FROM public.sales_process_cutover_items item
 JOIN public.sales_process_cutover_plans plan ON plan.company_id=item.company_id AND plan.id=item.cutover_plan_id
 JOIN public.sales_headers source ON source.company_id=item.company_id AND source.id=item.source_document_id
 JOIN public.company_sales_process_settings setting ON setting.company_id=item.company_id
 WHERE item.company_id=v_company AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
 AND plan.status='APPLIED' AND plan.target_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
 AND item.item_status='KEPT' AND item.source_document_type='RETAIL_SALE'
 AND item.blocker_codes='["OPEN_PROCUREMENT_MUST_FINISH"]'::jsonb AND item.target_document_id IS NULL
 AND NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_audit audit WHERE audit.company_id=item.company_id
 AND audit.cutover_item_id=item.id AND audit.action='APPLY_ITEM')),'[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.get_retained_sales_process_recovery_candidates() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_retained_sales_process_recovery_candidates() TO authenticated,service_role;

ALTER FUNCTION private.backoffice_sales_order_snapshot(uuid,uuid) RENAME TO office_snapshot_before_recovery_activity;
CREATE FUNCTION private.backoffice_sales_order_snapshot(p_company_id uuid,p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_result jsonb;v_activity jsonb;
BEGIN
 v_result:=private.office_snapshot_before_recovery_activity(p_company_id,p_order_id);
 SELECT COALESCE(jsonb_agg(jsonb_build_object('action','CUTOVER_RECOVERY','actorId',audit.actor_id,
 'actorName',profile.name,'createdAt',audit.created_at,'reason','Dipindahkan dari '||item.source_document_no||'; Stock Request lama dipertahankan.',
 'relatedDocumentId',item.source_document_id,'relatedDocumentNo',item.source_document_no,'relatedDocumentType','RETAIL_SALE')),'[]'::jsonb)
 INTO v_activity FROM public.sales_process_cutover_audit audit
 JOIN public.sales_process_cutover_items item ON item.company_id=audit.company_id AND item.id=audit.cutover_item_id
 LEFT JOIN public.profiles profile ON profile.id=audit.actor_id
 WHERE audit.company_id=p_company_id AND audit.action='APPLY_ITEM'
 AND audit.after_state->'converterResult'->>'targetDocumentId'=p_order_id::text;
 SELECT COALESCE(jsonb_agg(value ORDER BY (value->>'createdAt')::timestamptz DESC),'[]'::jsonb)
 INTO v_activity FROM jsonb_array_elements(COALESCE(v_result->'activity','[]'::jsonb)||v_activity);
 RETURN jsonb_set(v_result,'{activity}',v_activity);
END $$;
REVOKE ALL ON FUNCTION private.backoffice_sales_order_snapshot(uuid,uuid),
 private.office_snapshot_before_recovery_activity(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.backoffice_sales_order_snapshot(uuid,uuid),
 private.office_snapshot_before_recovery_activity(uuid,uuid) TO service_role;

ALTER FUNCTION public.get_sales_document_activity() SET SCHEMA private;
ALTER FUNCTION private.get_sales_document_activity() RENAME TO retail_activity_before_recovery;
CREATE FUNCTION public.get_sales_document_activity()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_result jsonb;v_company uuid:=public.private_active_company_id();
BEGIN
 v_result:=private.retail_activity_before_recovery();
 RETURN COALESCE((SELECT jsonb_agg(item.value||CASE WHEN audit.id IS NULL THEN '{}'::jsonb ELSE
 jsonb_build_object('cutover',jsonb_build_object('createdAt',audit.created_at,'actorName',profile.name,
 'targetDocumentId',audit.after_state->'converterResult'->>'targetDocumentId',
 'targetDocumentNo',audit.after_state->'converterResult'->>'targetDocumentNo','companyId',v_company)) END ORDER BY item.ordinality)
 FROM jsonb_array_elements(v_result) WITH ORDINALITY item(value,ordinality)
 LEFT JOIN LATERAL(SELECT history.* FROM public.sales_process_cutover_audit history
 WHERE history.company_id=v_company AND history.action='APPLY_ITEM'
 AND history.after_state->'converterResult'->>'sourceDocumentId'=item.value->>'salesId'
 ORDER BY history.created_at DESC,history.id DESC LIMIT 1) audit ON true
 LEFT JOIN public.profiles profile ON profile.id=audit.actor_id),'[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION private.retail_activity_before_recovery() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.retail_activity_before_recovery() TO service_role;
REVOKE ALL ON FUNCTION public.get_sales_document_activity() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_document_activity() TO authenticated,service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260916102000','retained_recovery_read_integration',
 'Super Admin recovery candidates and existing document activity/source-target read links. No backfill/UI tab/template/operational mutation.');
NOTIFY pgrst,'reload schema';

$release_20260916102000$;
 END IF;
END $install_20260916102000$;
DO $verify$ DECLARE v_bad text; BEGIN
 SELECT string_agg(signature,', ') INTO v_bad FROM (WITH expected(signature,digest) AS (VALUES
('public.cancel_backoffice_sales_order(uuid,bigint,uuid,text)','baa03a4d590294eceaffd282e18c338e'),
('public.get_retained_sales_process_recovery_candidates()','6d5754be9bb39ceb349fffd3314175b3'),
('public.get_sales_document_activity()','e0d3679a32b286fa8bbbbff38b6b29e5'),
('public.recover_retained_sales_process_order(uuid,bigint,bigint,bigint,uuid)','23b49a323c689b20a379ea7c6cd3c51a'),
('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)','f893bd8e378d7bb39672f22e5c019bcc'),
('private.backoffice_sales_order_snapshot(uuid,uuid)','9119cadd4d7fb31657d5017fe1985730'),
('private.convert_backoffice_order_to_retail_sale(uuid,uuid,uuid,uuid)','a98149d9d85d6573098aab3b2bdbcbb5'),
('private.convert_retail_sale_to_backoffice_order(uuid,uuid,uuid,uuid)','bf98042e7da5544a31b9f286cad3b5d6'),
('private.get_sales_process_cutover_plan_core(uuid,uuid)','f504b314061d39351f5484d99b771916'),
('private.get_sales_process_cutover_preview_core(uuid,text)','070abe6ff3564930c88d54c7296c5a2b'),
('private.recompose_office_pre_dispatch_fulfillment(uuid,uuid)','54d23f9ddde0599a228cd18d2a5ddaa0'),
('private.refresh_sales_order_procurement_demand(uuid,uuid,uuid,uuid,text)','1c89a0804fd4d396c9ec02b861d1c894'),
('private.release_office_untouched_fulfillment(uuid,uuid,uuid,text)','5593afcf08ddf21998bdbd15f19fe3e5'),
('private.sync_office_cutover_procurement(uuid,uuid,uuid,uuid)','aec5e7d0fbcf47428afafc89ff3ff146'),
('private.validate_office_untouched_fulfillment(uuid,uuid)','fc76c9d2bc6724e2376b1ecef1be3b81')
), actual AS (SELECT expected.*,to_regprocedure(signature) oid FROM expected)
SELECT signature,CASE WHEN oid IS NOT NULL AND md5(replace(pg_get_functiondef(oid),chr(13)||chr(10),chr(10)))=digest THEN 'PASS' ELSE 'FAIL' END status FROM actual) checked WHERE status<>'PASS';
 IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'RELEASE_RUNTIME_DRIFT: %',v_bad; END IF;
END $verify$;
COMMIT;

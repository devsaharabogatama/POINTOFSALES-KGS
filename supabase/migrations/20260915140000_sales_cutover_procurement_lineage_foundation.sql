-- Recovery foundation only. DOES NOT enable conversion or repair live orders.
BEGIN;
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
COMMIT;

-- ACP-4G: enforce Stock Opname Backoffice and blind-count capabilities.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812180000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-4F required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260812190000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
      WHERE permission_key='inventory.stock_opnames'
        AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'STOCK_OPNAME_PERMISSION_NOT_SHADOW';
  END IF;
  IF to_regprocedure('private.post_stock_opname(uuid,bigint,uuid)') IS NULL
     OR to_regprocedure('private.save_stock_adjustment_document(uuid,bigint,uuid,date,text,jsonb)') IS NULL
     OR to_regprocedure('private.post_stock_adjustment(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'STOCK_OPNAME_TRUSTED_ADJUSTMENT_CORE_REQUIRED';
  END IF;
END
$guard$;

-- Keep the established reviewer set aligned with the proven Opname runtime.
-- Warehouse Admin remains VIEW-only unless separately assigned Store Manager.
UPDATE public.access_permission_catalog SET
  operator_roles=ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER']::TEXT[],
  catalog_version=catalog_version+1,updated_at=clock_timestamp()
WHERE permission_key='inventory.stock_opnames'
  AND operator_roles=ARRAY[
    'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'
  ]::TEXT[];

-- Preserve proven lifecycle implementations as private cores. The Post core
-- was already moved and linked to private Adjustment cores by ACP-4F.
ALTER FUNCTION public.save_stock_opname_session(
  UUID,BIGINT,UUID,TEXT,UUID,JSONB,TEXT
) SET SCHEMA private;
ALTER FUNCTION public.start_stock_opname(UUID,BIGINT) SET SCHEMA private;
ALTER FUNCTION public.record_stock_opname_count(
  UUID,BIGINT,UUID,NUMERIC,TEXT
) SET SCHEMA private;
ALTER FUNCTION public.complete_stock_opname(UUID,BIGINT) SET SCHEMA private;
ALTER FUNCTION public.request_stock_opname_recount(
  UUID,BIGINT,UUID
) SET SCHEMA private;
ALTER FUNCTION public.cancel_stock_opname(UUID,BIGINT) SET SCHEMA private;
ALTER FUNCTION public.get_stock_opname_blind_session(UUID) SET SCHEMA private;

-- Blind count is a deliberately narrower channel than Backoffice VIEW. The
-- existing Store/Warehouse helper remains the authority ceiling. Overrides can
-- only remove that access; they can never grant Store or Warehouse scope.
CREATE FUNCTION private.acp_require_stock_opname_counter(
  p_company_id UUID,p_warehouse_id UUID,p_capability TEXT
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_actor UUID:=auth.uid();v_resolution JSONB;v_preset TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF upper(p_capability) NOT IN('CREATE_DRAFT','EDIT_DRAFT','CANCEL_FINAL') THEN
    RAISE EXCEPTION 'STOCK_OPNAME_COUNTER_CAPABILITY_INVALID';
  END IF;
  IF NOT public.private_stock_opname_counter_allowed(
    p_company_id,p_warehouse_id
  ) THEN RAISE EXCEPTION 'STOCK_OPNAME_COUNTER_REQUIRED'; END IF;

  v_resolution:=private.acp_resolve_permission(
    p_company_id,v_actor,'inventory.stock_opnames');
  v_preset:=v_resolution->>'restrictionPreset';
  IF (v_resolution->>'enforced')::BOOLEAN
     AND v_preset IN('LIHAT_SAJA','TANPA_AKSES') THEN
    RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
  END IF;
  RETURN v_resolution;
END
$$;

CREATE FUNCTION public.save_stock_opname_session(
  p_opname_id UUID,p_master_version BIGINT,p_warehouse_id UUID,
  p_scope_type TEXT,p_category_id UUID,p_product_ids JSONB,p_notes TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_stock_opname_counter(
    v_company,p_warehouse_id,
    CASE WHEN p_opname_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  RETURN private.save_stock_opname_session(
    p_opname_id,p_master_version,p_warehouse_id,p_scope_type,p_category_id,
    p_product_ids,p_notes);
END
$$;

CREATE FUNCTION public.start_stock_opname(
  p_opname_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_warehouse UUID;
BEGIN
  SELECT warehouse_id INTO v_warehouse FROM public.stock_opnames
  WHERE company_id=v_company AND id=p_opname_id;
  IF v_warehouse IS NULL THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  PERFORM private.acp_require_stock_opname_counter(
    v_company,v_warehouse,'EDIT_DRAFT');
  RETURN private.start_stock_opname(p_opname_id,p_master_version);
END
$$;

CREATE FUNCTION public.record_stock_opname_count(
  p_opname_id UUID,p_master_version BIGINT,p_product_id UUID,
  p_physical_qty NUMERIC,p_notes TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_warehouse UUID;
BEGIN
  SELECT warehouse_id INTO v_warehouse FROM public.stock_opnames
  WHERE company_id=v_company AND id=p_opname_id;
  IF v_warehouse IS NULL THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  PERFORM private.acp_require_stock_opname_counter(
    v_company,v_warehouse,'EDIT_DRAFT');
  RETURN private.record_stock_opname_count(
    p_opname_id,p_master_version,p_product_id,p_physical_qty,p_notes);
END
$$;

CREATE FUNCTION public.complete_stock_opname(
  p_opname_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_warehouse UUID;
BEGIN
  SELECT warehouse_id INTO v_warehouse FROM public.stock_opnames
  WHERE company_id=v_company AND id=p_opname_id;
  IF v_warehouse IS NULL THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  PERFORM private.acp_require_stock_opname_counter(
    v_company,v_warehouse,'EDIT_DRAFT');
  RETURN private.complete_stock_opname(p_opname_id,p_master_version);
END
$$;

CREATE FUNCTION public.request_stock_opname_recount(
  p_opname_id UUID,p_master_version BIGINT,p_opname_detail_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();v_warehouse UUID;
  v_status public.opname_status;v_line_status TEXT;
BEGIN
  SELECT opname.warehouse_id,opname.status,line.line_status
  INTO v_warehouse,v_status,v_line_status
  FROM public.stock_opnames opname JOIN public.stock_opname_details line
    ON line.company_id=opname.company_id AND line.opname_id=opname.id
  WHERE opname.company_id=v_company AND opname.id=p_opname_id
    AND line.id=p_opname_detail_id;
  IF v_warehouse IS NULL THEN RAISE EXCEPTION 'STOCK_OPNAME_LINE_NOT_FOUND'; END IF;
  IF v_status='COUNTING'::public.opname_status
     AND v_line_status='RECOUNT_REQUIRED' THEN
    PERFORM private.acp_require_stock_opname_counter(
      v_company,v_warehouse,'EDIT_DRAFT');
  ELSE
    PERFORM private.acp_require_permission_capability(
      v_company,'inventory.stock_opnames','REVIEW');
  END IF;
  RETURN private.request_stock_opname_recount(
    p_opname_id,p_master_version,p_opname_detail_id);
END
$$;

CREATE OR REPLACE FUNCTION public.post_stock_opname(
  p_opname_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_opnames','POST');
  RETURN private.post_stock_opname(
    p_opname_id,p_master_version,p_idempotency_key);
END
$$;

CREATE FUNCTION public.cancel_stock_opname(
  p_opname_id UUID,p_master_version BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();v_warehouse UUID;
  v_creator UUID;
BEGIN
  SELECT warehouse_id,created_by INTO v_warehouse,v_creator
  FROM public.stock_opnames
  WHERE company_id=v_company AND id=p_opname_id;
  IF v_warehouse IS NULL THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  IF v_creator=auth.uid() AND public.private_stock_opname_counter_allowed(
    v_company,v_warehouse
  ) THEN
    PERFORM private.acp_require_stock_opname_counter(
      v_company,v_warehouse,'CANCEL_FINAL');
  ELSE
    PERFORM private.acp_require_permission_capability(
      v_company,'inventory.stock_opnames','CANCEL_FINAL');
  END IF;
  RETURN private.cancel_stock_opname(p_opname_id,p_master_version);
END
$$;

CREATE FUNCTION public.get_stock_opname_blind_session(p_opname_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_warehouse UUID;
BEGIN
  SELECT warehouse_id INTO v_warehouse FROM public.stock_opnames
  WHERE company_id=v_company AND id=p_opname_id;
  IF v_warehouse IS NULL THEN RAISE EXCEPTION 'STOCK_OPNAME_NOT_FOUND'; END IF;
  PERFORM private.acp_require_stock_opname_counter(
    v_company,v_warehouse,'EDIT_DRAFT');
  RETURN private.get_stock_opname_blind_session(p_opname_id);
END
$$;

CREATE FUNCTION public.get_inventory_stock_opnames()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();v_sessions JSONB;
  v_details JSONB;v_attempts JSONB;v_warehouses JSONB;
  v_adjustments JSONB;v_actors JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_opnames','VIEW');

  SELECT COALESCE(jsonb_agg(to_jsonb(session_row)
    ORDER BY session_row.created_at DESC,session_row.id),'[]'::JSONB)
  INTO v_sessions FROM (
    SELECT opname.id,opname.company_id,opname.opname_no,
      opname.warehouse_id,opname.status,opname.notes,opname.created_by,
      opname.created_at,opname.scope_type,opname.category_id,
      opname.count_started_at,opname.movement_watermark_at,
      opname.completed_by,opname.completed_at,opname.reviewed_by,
      opname.reviewed_at,opname.adjustment_document_id,opname.posted_by,
      opname.posted_at,opname.canceled_by,opname.canceled_at,
      opname.master_version,opname.updated_at
    FROM public.stock_opnames opname WHERE opname.company_id=v_company
    ORDER BY opname.created_at DESC,opname.id LIMIT 500
  ) session_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
    ORDER BY line_row.opname_id,line_row.product_name_snapshot,line_row.id),
    '[]'::JSONB) INTO v_details FROM (
    SELECT line.id,line.company_id,line.opname_id,line.product_id,
      line.system_qty,line.physical_qty,line.difference,line.notes,
      line.line_status,line.base_uom_id,line.system_qty_at_start,
      line.expected_qty_at_count,line.variance_at_count,line.count_started_at,
      line.counted_at,line.counter_id,line.movement_watermark_at,
      line.superseded_by_line_id,line.recount_requested_by,
      line.recount_requested_at,line.adjustment_line_id,
      line.product_sku_snapshot,line.product_name_snapshot,
      line.base_uom_name_snapshot
    FROM public.stock_opname_details line
    WHERE line.company_id=v_company AND line.opname_id IN(
      SELECT opname.id FROM public.stock_opnames opname
      WHERE opname.company_id=v_company
      ORDER BY opname.created_at DESC,opname.id LIMIT 500)
    ORDER BY line.opname_id,line.product_name_snapshot,line.id LIMIT 20000
  ) line_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(attempt_row)
    ORDER BY attempt_row.opname_id,attempt_row.attempt_no,attempt_row.id),
    '[]'::JSONB) INTO v_attempts FROM (
    SELECT attempt.id,attempt.opname_id,attempt.opname_detail_id,
      attempt.attempt_no,attempt.physical_qty,attempt.count_started_at,
      attempt.counted_at,attempt.counter_id,
      attempt.movement_count_in_window,attempt.result_status,attempt.notes
    FROM public.stock_opname_count_attempts attempt
    WHERE attempt.company_id=v_company AND attempt.opname_id IN(
      SELECT opname.id FROM public.stock_opnames opname
      WHERE opname.company_id=v_company
      ORDER BY opname.created_at DESC,opname.id LIMIT 500)
    ORDER BY attempt.opname_id,attempt.attempt_no,attempt.id LIMIT 30000
  ) attempt_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(warehouse_row)
    ORDER BY warehouse_row.name,warehouse_row.id),'[]'::JSONB)
  INTO v_warehouses FROM (
    SELECT warehouse.id,warehouse.name,warehouse.warehouse_type,
      warehouse.location,warehouse.store_id,warehouse.is_active
    FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND EXISTS(
      SELECT 1 FROM public.stock_opnames opname
      WHERE opname.company_id=v_company
        AND opname.warehouse_id=warehouse.id)
    ORDER BY warehouse.name,warehouse.id LIMIT 5000
  ) warehouse_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(adjustment_row)
    ORDER BY adjustment_row.posted_at DESC,adjustment_row.id),'[]'::JSONB)
  INTO v_adjustments FROM (
    SELECT document.id,document.document_no,document.status,
      document.total_gain_quantity_base,document.total_loss_quantity_base,
      document.total_gain_value,document.total_loss_value,document.posted_at
    FROM public.stock_adjustment_documents document
    WHERE document.company_id=v_company AND EXISTS(
      SELECT 1 FROM public.stock_opnames opname
      WHERE opname.company_id=v_company
        AND opname.adjustment_document_id=document.id)
    ORDER BY document.posted_at DESC,document.id LIMIT 5000
  ) adjustment_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(actor_row)
    ORDER BY actor_row.name,actor_row.id),'[]'::JSONB)
  INTO v_actors FROM (
    SELECT profile.id,profile.name FROM public.profiles profile
    WHERE profile.id IN(
      SELECT actor_id FROM (
        SELECT created_by actor_id FROM public.stock_opnames
          WHERE company_id=v_company
        UNION SELECT completed_by FROM public.stock_opnames
          WHERE company_id=v_company
        UNION SELECT reviewed_by FROM public.stock_opnames
          WHERE company_id=v_company
        UNION SELECT posted_by FROM public.stock_opnames
          WHERE company_id=v_company
        UNION SELECT canceled_by FROM public.stock_opnames
          WHERE company_id=v_company
        UNION SELECT counter_id FROM public.stock_opname_details
          WHERE company_id=v_company
        UNION SELECT recount_requested_by FROM public.stock_opname_details
          WHERE company_id=v_company
      ) actor WHERE actor_id IS NOT NULL)
    ORDER BY profile.name,profile.id LIMIT 5000
  ) actor_row;

  RETURN jsonb_build_object(
    'companyId',v_company,'data',v_sessions,'details',v_details,
    'attempts',v_attempts,'warehouses',v_warehouses,
    'adjustments',v_adjustments,'actors',v_actors);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='inventory.stock_opnames'
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN
    RAISE EXCEPTION 'STOCK_OPNAME_PERMISSION_CUTOVER_FAILED';
  END IF;
END
$enforce$;

REVOKE SELECT ON public.stock_opnames,public.stock_opname_details,
  public.stock_opname_count_attempts,public.stock_opname_audit
FROM authenticated;

REVOKE ALL ON FUNCTION
  private.save_stock_opname_session(UUID,BIGINT,UUID,TEXT,UUID,JSONB,TEXT),
  private.start_stock_opname(UUID,BIGINT),
  private.record_stock_opname_count(UUID,BIGINT,UUID,NUMERIC,TEXT),
  private.complete_stock_opname(UUID,BIGINT),
  private.request_stock_opname_recount(UUID,BIGINT,UUID),
  private.post_stock_opname(UUID,BIGINT,UUID),
  private.cancel_stock_opname(UUID,BIGINT),
  private.get_stock_opname_blind_session(UUID),
  private.acp_require_stock_opname_counter(UUID,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.save_stock_opname_session(UUID,BIGINT,UUID,TEXT,UUID,JSONB,TEXT),
  private.start_stock_opname(UUID,BIGINT),
  private.record_stock_opname_count(UUID,BIGINT,UUID,NUMERIC,TEXT),
  private.complete_stock_opname(UUID,BIGINT),
  private.request_stock_opname_recount(UUID,BIGINT,UUID),
  private.post_stock_opname(UUID,BIGINT,UUID),
  private.cancel_stock_opname(UUID,BIGINT),
  private.get_stock_opname_blind_session(UUID),
  private.acp_require_stock_opname_counter(UUID,UUID,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION
  public.private_stock_opname_counter_allowed(UUID,UUID),
  public.get_stock_opname_adjustment_references(),
  public.save_stock_opname_session(UUID,BIGINT,UUID,TEXT,UUID,JSONB,TEXT),
  public.start_stock_opname(UUID,BIGINT),
  public.record_stock_opname_count(UUID,BIGINT,UUID,NUMERIC,TEXT),
  public.complete_stock_opname(UUID,BIGINT),
  public.request_stock_opname_recount(UUID,BIGINT,UUID),
  public.post_stock_opname(UUID,BIGINT,UUID),
  public.cancel_stock_opname(UUID,BIGINT),
  public.get_stock_opname_blind_session(UUID),
  public.get_inventory_stock_opnames()
FROM PUBLIC,anon;
REVOKE EXECUTE ON FUNCTION
  public.private_stock_opname_counter_allowed(UUID,UUID),
  public.get_stock_opname_adjustment_references()
FROM authenticated;
GRANT EXECUTE ON FUNCTION
  public.save_stock_opname_session(UUID,BIGINT,UUID,TEXT,UUID,JSONB,TEXT),
  public.start_stock_opname(UUID,BIGINT),
  public.record_stock_opname_count(UUID,BIGINT,UUID,NUMERIC,TEXT),
  public.complete_stock_opname(UUID,BIGINT),
  public.request_stock_opname_recount(UUID,BIGINT,UUID),
  public.post_stock_opname(UUID,BIGINT,UUID),
  public.cancel_stock_opname(UUID,BIGINT),
  public.get_stock_opname_blind_session(UUID),
  public.get_inventory_stock_opnames()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812190000','acp_phase4g_stock_opname_permission_enforcement',
  'Enforced Stock Opname Backoffice capabilities and restriction-aware blind count while preserving Store scope and trusted Adjustment posting');

NOTIFY pgrst, 'reload schema';

COMMIT;

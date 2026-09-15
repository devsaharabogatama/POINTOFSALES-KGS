-- Explicit recovery of historical procurement-only KEPT Retail items.
-- No automatic backfill; historical plan/item/KEEP_ITEM audit are untouched.
BEGIN;
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
COMMIT;

-- Historical standalone lifecycle blocker is resolved by 20260915142000.
-- Install only with the full verified atomic release, never this runtime alone.
-- Preserve procurement identities and synchronize Office lifecycle; no live backfill.
BEGIN;
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
COMMIT;

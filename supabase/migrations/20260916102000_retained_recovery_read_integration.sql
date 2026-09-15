-- Existing settings and Sales document-log readers; no new tabs/templates.
BEGIN;
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
COMMIT;

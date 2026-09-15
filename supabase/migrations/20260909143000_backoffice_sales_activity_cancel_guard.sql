-- Activity read model and guarded cancellation of an unfulfilled confirmed SO.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909142000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision status runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909143000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909143000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF to_regprocedure('private.backoffice_sales_order_snapshot_before_activity(uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: activity compatibility function already exists';
  END IF;
END
$guard$;

DO $patch_cancel$
DECLARE
  v_definition text;
  v_needle text:='IF v_document.status NOT IN(''DRAFT'',''SENT'') THEN RAISE EXCEPTION ''BACKOFFICE_SALES_CANCEL_STATE_INVALID''; END IF;';
  v_replacement text:='IF NOT (v_document.status IN(''DRAFT'',''SENT'') OR (v_document.status=''CONFIRMED'' AND v_document.fulfillment_status=''CONFIRMED'')) THEN RAISE EXCEPTION ''BACKOFFICE_SALES_CANCEL_STATE_INVALID''; END IF;';
BEGIN
  SELECT pg_get_functiondef(
    'private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)'::regprocedure
  ) INTO v_definition;
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))
       / nullif(length(v_needle),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cancel state boundary drift';
  END IF;
  EXECUTE replace(v_definition,v_needle,v_replacement);
END
$patch_cancel$;

ALTER FUNCTION private.backoffice_sales_order_snapshot(uuid,uuid)
  RENAME TO backoffice_sales_order_snapshot_before_activity;

CREATE FUNCTION private.backoffice_sales_order_snapshot(
  p_company_id uuid,p_order_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT private.backoffice_sales_order_snapshot_before_activity(
    p_company_id,p_order_id)||jsonb_build_object(
      'activity',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'action',activity.action,'reason',activity.reason,
        'actorId',activity.actor_id,'actorName',profile.name,
        'createdAt',activity.created_at)
        ORDER BY activity.created_at DESC,activity.id DESC)
      FROM (SELECT audit.id,audit.action,audit.reason,audit.actor_id,audit.created_at
        FROM public.backoffice_sales_order_audit audit
        WHERE audit.company_id=p_company_id AND audit.sales_order_id=p_order_id
        ORDER BY audit.created_at DESC,audit.id DESC LIMIT 50) activity
      LEFT JOIN public.profiles profile ON profile.id=activity.actor_id),'[]'::jsonb))
$$;

REVOKE ALL ON FUNCTION
  private.backoffice_sales_order_snapshot_before_activity(uuid,uuid),
  private.backoffice_sales_order_snapshot(uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.backoffice_sales_order_snapshot_before_activity(uuid,uuid),
  private.backoffice_sales_order_snapshot(uuid,uuid)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909143000','backoffice_sales_activity_cancel_guard',
  'Expose immutable SO activity history and allow cancel only before fulfillment starts; in-transit/completed remain closed and require fulfillment correction or Return');

NOTIFY pgrst,'reload schema';
COMMIT;

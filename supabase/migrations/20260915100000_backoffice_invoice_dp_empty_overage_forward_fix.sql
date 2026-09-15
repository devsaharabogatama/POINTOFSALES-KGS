-- Additive compatibility fix: valid DP has no accepted-overage trigger input.
BEGIN;
DO $fix$
DECLARE v_body text;v_old text:=$m$set_config('kgs.backoffice_invoice_accepted_overage_lines',v_overage::text,true)$m$;
  v_new text:=$m$set_config('kgs.backoffice_invoice_accepted_overage_lines',CASE WHEN v_type='DOWN_PAYMENT' THEN '' ELSE v_overage::text END,true)$m$;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260915100000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN('20260912124000','20260912137000','20260912140000'))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: DP/overage chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
    OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active queue';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')) INTO v_body;
  IF v_body IS NULL OR (length(v_body)-length(replace(v_body,v_old,'')))/length(v_old)<>1
    OR position($m$(v_type='DOWN_PAYMENT' AND jsonb_array_length(v_overage)>0)$m$ in v_body)=0
    OR position($m$BACKOFFICE_INVOICE_DELIVERY_FEE_NOT_ALLOWED_ON_DP$m$ in v_body)=0
    OR position($m$NEW.invoice_type<>'REGULAR'$m$ in pg_get_functiondef(to_regprocedure(
      'private.trg_backoffice_sales_invoice_accepted_overage_lines()')))=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: DP/overage runtime drift';
  END IF;
  EXECUTE replace(v_body,v_old,v_new);
  SELECT pg_get_functiondef(to_regprocedure('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')) INTO v_body;
  IF position(v_new in v_body)=0 OR position(v_old in v_body)>0 THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: DP marker fix missing';
  END IF;
END $fix$;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260915100000','backoffice_invoice_dp_empty_overage_forward_fix',
  'Valid DP clears accepted-overage input; regular payload, rejection guards, cleanup, lock, audit and financial contracts unchanged');
NOTIFY pgrst,'reload schema';
COMMIT;

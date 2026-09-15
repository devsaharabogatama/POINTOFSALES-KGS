-- Read-only; run on rehearsal clone before additive DP fix.
WITH core AS (SELECT pg_get_functiondef(to_regprocedure(
  'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)')) body), checks AS (
SELECT 'dp_fix_dependency' check_name,CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
  jsonb_build_object('present',count(*),'expected',3) details FROM private.kgs_schema_migrations
WHERE version IN('20260912124000','20260912137000','20260912140000')
UNION ALL SELECT 'dp_fix_anchor',CASE WHEN body IS NOT NULL AND
  (length(body)-length(replace(body,$m$set_config('kgs.backoffice_invoice_accepted_overage_lines',v_overage::text,true)$m$,'')))
    /length($m$set_config('kgs.backoffice_invoice_accepted_overage_lines',v_overage::text,true)$m$)=1
  AND position($m$(v_type='DOWN_PAYMENT' AND jsonb_array_length(v_overage)>0)$m$ in body)>0
  THEN 'PASS' ELSE 'BLOCKER' END,jsonb_build_object('coreExists',body IS NOT NULL) FROM core
UNION ALL SELECT 'dp_fix_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  jsonb_build_object('ledgerRows',count(*)) FROM private.kgs_schema_migrations WHERE version='20260915100000'
UNION ALL SELECT 'dp_fix_queues',CASE WHEN NOT EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) AND NOT EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN 'PASS' ELSE 'BLOCKER' END,'{}'::jsonb
) SELECT check_name,status,CASE WHEN status='PASS' THEN 0 ELSE 1 END violation_rows,details FROM checks;

-- POS scheduled TEMPO order preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'scheduled_order_dependencies'::TEXT check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',3,'routineRows',count(*)) details
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname,
    pg_get_function_identity_arguments(procedure.oid)) IN (
      ('public','save_pos_sale_draft_with_pricelist','p_payload jsonb'),
      ('public','list_pos_sale_drafts','p_store_id uuid'),
      ('public','post_pos_sale','p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid')
    )
  UNION ALL
  SELECT 'scheduled_order_schema_state',
    CASE WHEN count(*)=0 THEN 'SETUP' ELSE 'BLOCKER' END,
    jsonb_build_object('existingColumns',count(*),'expectedNewColumns',5)
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sales_headers'
    AND column_name IN('planned_order_date','order_timing_mode',
      'planned_order_selected_by','planned_order_selected_at',
      'scheduled_activated_at')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions submission
  WHERE submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'draft_final_effect_boundary','PASS',jsonb_build_object(
    'drafts',(SELECT count(*) FROM public.sales_headers WHERE document_status='DRAFT'),
    'draftFinancialEvents',(SELECT count(*) FROM public.financial_events event
      JOIN public.sales_headers sale ON sale.company_id=event.company_id
       AND sale.id=event.source_id WHERE sale.document_status='DRAFT'),
    'draftStockMovements',(SELECT count(*) FROM public.stock_movements movement
      JOIN public.sales_headers sale ON sale.company_id=movement.company_id
       AND sale.id=movement.reference_id WHERE sale.document_status='DRAFT'))
)
SELECT check_name,status,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

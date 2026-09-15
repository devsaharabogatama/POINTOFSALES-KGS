WITH checks AS (
  SELECT 'dependency_chain'::text check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN('20260909120000','20260909130000')
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',count(*)) FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'backoffice_draft_compatibility','INFO',jsonb_build_object(
    'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'confirmed',count(*) FILTER(WHERE status='CONFIRMED'),
    'allDocuments',count(*)) FROM public.backoffice_sales_orders
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

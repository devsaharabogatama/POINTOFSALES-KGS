-- READ ONLY: targeted existing-data/input guards after supplied delta inventory.
-- No application RPC executed. Run whole file before installing migrations.
WITH duplicate_receipts AS (
  SELECT company_id,supplier_order_id,warehouse_id,count(*) draft_count
  FROM public.goods_receipt_documents
  WHERE source_channel='BACKOFFICE' AND status='DRAFT'
  GROUP BY company_id,supplier_order_id,warehouse_id HAVING count(*)>1
), checks AS (
  SELECT 'receipt_active_draft_uniqueness'::text check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    count(*)::bigint violation_rows,jsonb_build_object('duplicatePairs',count(*),
      'extraDrafts',COALESCE(sum(draft_count-1),0),
      'rule','Exact unique-index input in 20260914180000; do not delete duplicate history') details
  FROM duplicate_receipts
  UNION ALL
  SELECT 'legacy_negative_reservation_evidence',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('invalidRows',count(*),'migration','20260910153000')
  FROM public.sales_stock_reservation_lines
  WHERE shortage_base_qty>0 AND (negative_policy_version IS NULL OR negative_permission_version IS NULL)
  UNION ALL
  SELECT 'legacy_negative_authorization_evidence',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('invalidRows',count(*),'migration','20260910153000')
  FROM public.pos_negative_stock_authorizations
  WHERE permission_id IS NULL OR NULLIF(btrim(reason),'') IS NULL
    OR policy_version<=0 OR permission_version<=0
  UNION ALL
  SELECT 'current_receipt_status_inventory','INFO',0,
    jsonb_build_object('statuses',COALESCE(jsonb_agg(to_jsonb(summary) ORDER BY summary.source_channel,summary.status),'[]'::jsonb))
  FROM (SELECT source_channel,status,count(*) rows FROM public.goods_receipt_documents
    GROUP BY source_channel,status) summary
  UNION ALL
  SELECT 'current_purchase_order_status_inventory','INFO',0,
    jsonb_build_object('statuses',COALESCE(jsonb_agg(to_jsonb(summary) ORDER BY summary.status),'[]'::jsonb))
  FROM (SELECT status,count(*) rows FROM public.supplier_order_documents GROUP BY status) summary
  UNION ALL
  SELECT 'receipt_line_no_dependency','INFO',0,jsonb_build_object(
    'installed',EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260825131000'),
    'prerequisiteInstalled',EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260825130000'),
    'action','Use rehearsed unapplied Receipt dependency; no ledger-only insertion')
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;

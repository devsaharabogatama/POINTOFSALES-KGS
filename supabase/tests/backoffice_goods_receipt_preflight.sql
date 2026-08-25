-- Backoffice Goods Receipt preflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_dependencies'::TEXT check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*),'expected',2) details
  FROM private.kgs_schema_migrations WHERE version IN('20260806040000','20260813000000')
  UNION ALL
  SELECT 'canonical_goods_receipt_runtime',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*),'expected',3) FROM unnest(ARRAY[
      'public.save_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)',
      'public.post_goods_receipt(uuid,bigint,uuid)',
      'public.cancel_goods_receipt(uuid,bigint)']) signature
    WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'nonterminal_goods_receipt','PASS',jsonb_build_object('drafts',count(*))
    FROM public.goods_receipt_documents WHERE status='DRAFT'
  UNION ALL
  SELECT 'receivable_supplier_order_scope','INFO',jsonb_build_object('orders',count(*))
    FROM public.supplier_order_documents WHERE status IN('CONFIRMED','PARTIALLY_RECEIVED')
  UNION ALL
  SELECT 'backoffice_goods_receipt_schema_state','SETUP',jsonb_build_object(
    'permissionExists',EXISTS(SELECT 1 FROM public.access_permission_catalog WHERE permission_key='purchase.goods_receipts'),
    'channelColumnExists',EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='goods_receipt_documents' AND column_name='source_channel'))
)
SELECT check_name,status,details FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 WHEN 'SETUP' THEN 2 ELSE 3 END,check_name;

-- Backoffice Goods Receipt postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,count(*)::BIGINT violation_rows,jsonb_build_object('ledgerRows',count(*)) details
    FROM private.kgs_schema_migrations WHERE version='20260825130000'
  UNION ALL
  SELECT 'workspace_line_number_forward_fix',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),jsonb_build_object('ledgerRows',count(*))
    FROM private.kgs_schema_migrations WHERE version='20260825131000'
  UNION ALL
  SELECT 'goods_receipt_permission_enforced',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),jsonb_build_object('rows',count(*))
    FROM public.access_permission_catalog WHERE permission_key='purchase.goods_receipts' AND enforcement_status='ENFORCED'
  UNION ALL
  SELECT 'required_backoffice_goods_receipt_routines',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,abs(4-count(*)),jsonb_build_object('routineRows',count(*),'expected',4)
    FROM unnest(ARRAY['public.get_backoffice_goods_receipt_workspace()','public.save_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb)','public.post_backoffice_goods_receipt(uuid,bigint,uuid)','public.cancel_backoffice_goods_receipt(uuid,bigint)']) signature WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'canonical_goods_receipt_public_runtime',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,abs(3-count(*)),jsonb_build_object('routineRows',count(*),'expected',3)
    FROM unnest(ARRAY['public.save_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)','public.post_goods_receipt(uuid,bigint,uuid)','public.cancel_goods_receipt(uuid,bigint)']) signature WHERE to_regprocedure(signature) IS NOT NULL
  UNION ALL
  SELECT 'private_goods_receipt_core_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('authenticatedExecutableRows',count(*))
    FROM unnest(ARRAY['private.backoffice_channel_post_goods_receipt_core(uuid,bigint,uuid)','private.backoffice_channel_cancel_goods_receipt_core(uuid,bigint)']) signature
    WHERE to_regprocedure(signature) IS NOT NULL AND has_function_privilege('authenticated',to_regprocedure(signature),'EXECUTE')
  UNION ALL
  SELECT 'backoffice_receipt_channel_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('rowCount',count(*)) FROM public.goods_receipt_documents WHERE (source_channel='POS' AND (receiving_session_id IS NULL OR receiving_pos_id IS NULL)) OR (source_channel='BACKOFFICE' AND (receiving_session_id IS NOT NULL OR receiving_pos_id IS NOT NULL))
  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('pairCount',count(*))
  FROM (
    SELECT COALESCE(stock.company_id,fifo.company_id) company_id
    FROM public.product_stocks stock
    FULL JOIN (SELECT company_id,product_id,warehouse_id,
        COALESCE(sum(qty_remaining),0) qty
      FROM public.product_batches GROUP BY company_id,product_id,warehouse_id) fifo
      ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
     AND fifo.warehouse_id=stock.warehouse_id
    WHERE COALESCE(fifo.qty,0)<0
       OR (COALESCE(stock.stock_qty,0)>=0
         AND COALESCE(stock.stock_qty,0)<>COALESCE(fifo.qty,0))
  ) mismatch
  UNION ALL
  SELECT 'backoffice_goods_receipt_inventory','INFO',0,jsonb_build_object('drafts',count(*) FILTER(WHERE status='DRAFT'),'posted',count(*) FILTER(WHERE status='POSTED'),'backofficeRows',count(*) FILTER(WHERE source_channel='BACKOFFICE')) FROM public.goods_receipt_documents
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;

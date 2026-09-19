-- SELECT-only verification for 20260919143000.
WITH checks AS (
  SELECT 'negative_stock_return_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260919143000'
  UNION ALL SELECT 'negative_stock_return_relation_contract',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    (3-count(*))::bigint,jsonb_build_object('present',count(*),'expected',3)
  FROM (SELECT name FROM unnest(ARRAY['purchase_return_stock_shortages',
      'purchase_return_shortage_replenishments','purchase_return_shortage_cost_adjustments']) name
    WHERE to_regclass('public.'||name) IS NOT NULL) relation
  UNION ALL SELECT 'negative_stock_return_runtime_contract',
    CASE WHEN count(*)=7 THEN 'PASS' ELSE 'FAIL' END,(7-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',7)
  FROM (SELECT signature FROM unnest(ARRAY[
      'public.get_backoffice_purchase_return_workspace(uuid)',
      'public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)',
      'public.post_backoffice_purchase_return(uuid,bigint,uuid)',
      'private.reconcile_negative_stock_replenishment()',
      'private.trg_purchase_return_shortage_cost_source()',
      'private.trg_purchase_return_shortage_journal_lines()',
      'private.trg_purchase_return_shortage_cost_posted()']) signature
    WHERE to_regprocedure(signature) IS NOT NULL) routine
  UNION ALL SELECT 'negative_stock_return_removed_fifo_gate',
    CASE WHEN bool_and(definition!~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
      AND definition!~'stock_qty[[:space:]]*>=[[:space:]]*v_line\.return_base_qty'
      AND definition!~'v_return_base[[:space:]]*>[[:space:]]*v_source\.qty_remaining') THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE definition~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
      OR definition~'stock_qty[[:space:]]*>=[[:space:]]*v_line\.return_base_qty'
      OR definition~'v_return_base[[:space:]]*>[[:space:]]*v_source\.qty_remaining')::bigint,
    jsonb_build_object('checked',count(*))
  FROM (SELECT pg_get_functiondef(signature::regprocedure) definition
    FROM unnest(ARRAY[
      'public.get_backoffice_purchase_return_workspace(uuid)',
      'public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)',
      'public.post_backoffice_purchase_return(uuid,bigint,uuid)']) signature) runtime
  UNION ALL SELECT 'negative_stock_return_shortage_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.purchase_return_stock_shortages shortage
  WHERE shortage.replenished_base_qty<0
    OR shortage.replenished_base_qty>shortage.shortage_base_qty
    OR (shortage.replenished_base_qty=shortage.shortage_base_qty)<>(shortage.reconciled_at IS NOT NULL)
    OR NOT EXISTS(SELECT 1 FROM public.purchase_return_fifo_allocations fifo
      WHERE fifo.company_id=shortage.company_id
        AND fifo.return_line_id=shortage.return_line_id
        AND fifo.document_id=shortage.document_id)
    OR shortage.replenished_base_qty<>COALESCE((SELECT sum(replenishment.replenished_base_qty)
      FROM public.purchase_return_shortage_replenishments replenishment
      WHERE replenishment.company_id=shortage.company_id
        AND replenishment.shortage_id=shortage.id),0)
    OR shortage.actual_cost_total<>COALESCE((SELECT sum(round(
        replenishment.replenished_base_qty*replenishment.actual_unit_cost,4))
      FROM public.purchase_return_shortage_replenishments replenishment
      WHERE replenishment.company_id=shortage.company_id
        AND replenishment.shortage_id=shortage.id),0)
    OR shortage.purchase_price_variance_total<>COALESCE((SELECT sum(
        replenishment.purchase_price_variance_total)
      FROM public.purchase_return_shortage_replenishments replenishment
      WHERE replenishment.company_id=shortage.company_id
        AND replenishment.shortage_id=shortage.id),0)
  UNION ALL SELECT 'negative_stock_return_trigger_contract',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,(4-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',4)
  FROM pg_trigger trigger_row
  WHERE NOT trigger_row.tgisinternal AND trigger_row.tgenabled<>'D'
    AND (trigger_row.tgrelid,trigger_row.tgname) IN(
      ('public.product_batches'::regclass,'g4_reconcile_negative_stock_replenishment'),
      ('public.financial_events'::regclass,'purchase_return_shortage_cost_source'),
      ('public.finance_journals'::regclass,'purchase_return_shortage_journal_lines'),
      ('public.financial_events'::regclass,'purchase_return_shortage_cost_posted'))
  UNION ALL SELECT 'negative_stock_return_permission_contract',
    CASE WHEN bool_and(NOT authenticated_select AND service_role_write)
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE authenticated_select OR NOT service_role_write)::bigint,
    jsonb_build_object('relations',count(*),'authenticatedDirectRead',
      count(*) FILTER(WHERE authenticated_select),'serviceRoleWrite',
      count(*) FILTER(WHERE service_role_write))
  FROM (SELECT relation,
      has_table_privilege('authenticated',relation,'SELECT') authenticated_select,
      has_table_privilege('service_role',relation,'SELECT,INSERT,UPDATE') service_role_write
    FROM unnest(ARRAY[
      'public.purchase_return_stock_shortages',
      'public.purchase_return_shortage_replenishments',
      'public.purchase_return_shortage_cost_adjustments']) relation) permission
  UNION ALL SELECT 'negative_stock_return_movement_constraint',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,(1-count(*))::bigint,
    jsonb_build_object('purchaseReturnNegativeBoundary',count(*)=1)
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.stock_movements'::regclass
    AND constraint_row.conname='stock_movements_balance_after_controlled'
    AND pg_get_constraintdef(constraint_row.oid)~'PURCHASE_RETURN'
  UNION ALL SELECT 'negative_stock_return_finance_catalog',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,(1-count(*))::bigint,
    jsonb_build_object('goodsReceiptPpvAllowed',count(*)=1)
  FROM public.system_events event
  WHERE event.system_key='GOODS_RECEIPT' AND event.is_active
    AND 'PURCHASE_PRICE_VARIANCE'=ANY(COALESCE(
      event.conditional_account_functions,ARRAY[]::text[]))
  UNION ALL SELECT 'negative_stock_return_ppv_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.purchase_return_shortage_cost_adjustments adjustment
  WHERE adjustment.status='POSTED' AND (NOT EXISTS(
      SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=adjustment.company_id
        AND journal.financial_event_id=adjustment.financial_event_id
        AND journal.status='POSTED' AND journal.total_debit=journal.total_credit)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines inventory_line
      JOIN public.finance_journals journal ON journal.company_id=inventory_line.company_id
        AND journal.id=inventory_line.journal_id
      WHERE journal.company_id=adjustment.company_id
        AND journal.financial_event_id=adjustment.financial_event_id
        AND inventory_line.line_no=900011
        AND inventory_line.account_id=adjustment.inventory_account_id
        AND inventory_line.debit-inventory_line.credit=
          -adjustment.purchase_price_variance_total)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines variance_line
      JOIN public.finance_journals journal ON journal.company_id=variance_line.company_id
        AND journal.id=variance_line.journal_id
      WHERE journal.company_id=adjustment.company_id
        AND journal.financial_event_id=adjustment.financial_event_id
        AND variance_line.line_no=900012
        AND variance_line.account_id=adjustment.purchase_price_variance_account_id
        AND variance_line.debit-variance_line.credit=
          adjustment.purchase_price_variance_total))
  UNION ALL SELECT 'negative_stock_return_runtime_inventory','INFO',0,
    jsonb_build_object('shortages',count(*),'openShortages',
      count(*) FILTER(WHERE reconciled_at IS NULL),'shortageBaseQty',
      COALESCE(sum(shortage_base_qty),0),'replenishedBaseQty',
      COALESCE(sum(replenished_base_qty),0))
  FROM public.purchase_return_stock_shortages
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;

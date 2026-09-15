-- SELECT-only verification for 20260910150000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910150000'
  UNION ALL
  SELECT 'delivery_fee_column_contract',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*))::bigint,jsonb_build_object('expected',3,'columnRows',count(*))
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public' AND (
    (column_state.table_name='backoffice_sales_orders'
      AND column_state.column_name IN('delivery_fee_amount','delivery_fee_invoice_display_mode'))
    OR (column_state.table_name='backoffice_sales_invoices'
      AND column_state.column_name='delivery_fee_amount'))
  UNION ALL
  SELECT 'delivery_fee_constraint_contract',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(3-count(*))::bigint,jsonb_build_object('expected',3,'constraintRows',count(*))
  FROM pg_constraint constraint_state WHERE
    (constraint_state.conrelid='public.backoffice_sales_orders'::regclass
      AND constraint_state.conname IN('backoffice_sales_orders_delivery_fee_check',
        'backoffice_sales_orders_amount_check')
      AND pg_get_constraintdef(constraint_state.oid) LIKE '%delivery_fee%')
    OR (constraint_state.conrelid='public.backoffice_sales_invoices'::regclass
      AND constraint_state.conname='backoffice_sales_invoices_shape_check'
      AND pg_get_constraintdef(constraint_state.oid) LIKE '%delivery_fee%')
  UNION ALL
  SELECT 'required_delivery_fee_routines',CASE WHEN count(*) FILTER(WHERE present)=10
      THEN 'PASS' ELSE 'FAIL' END,
    (10-count(*) FILTER(WHERE present))::bigint,
    jsonb_build_object('expected',10,'routineRows',count(*) FILTER(WHERE present),
      'missing',COALESCE(jsonb_agg(signature ORDER BY signature)
        FILTER(WHERE NOT present),'[]'))
  FROM (SELECT signature,to_regprocedure(signature) IS NOT NULL present FROM (VALUES
      ('public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)'),
      ('public.save_backoffice_sales_order_draft_before_delivery_fee(uuid,bigint,uuid,jsonb)'),
      ('private.trg_backoffice_sales_order_delivery_fee()'),
      ('private.trg_backoffice_sales_invoice_delivery_fee()'),
      ('private.backoffice_sales_order_snapshot(uuid,uuid)'),
      ('private.backoffice_sales_order_snapshot_before_delivery_fee(uuid,uuid)'),
      ('private.backoffice_sales_invoice_snapshot(uuid,uuid)'),
      ('private.backoffice_sales_invoice_snapshot_before_delivery_fee(uuid,uuid)'),
      ('private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)'),
      ('private.save_backoffice_sales_invoice_draft_core_before_delivery_fee(uuid,bigint,uuid,uuid,jsonb)')
    ) required(signature)) required_routines
  UNION ALL
  SELECT 'delivery_fee_trigger_contract',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*))::bigint,jsonb_build_object('expected',2,'triggerRows',count(*))
  FROM pg_trigger trigger_state WHERE NOT trigger_state.tgisinternal
    AND trigger_state.tgname IN('backoffice_sales_order_delivery_fee_guard',
      'backoffice_sales_invoice_delivery_fee_guard') AND trigger_state.tgenabled<>'D'
  UNION ALL
  SELECT 'delivery_fee_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee IN('anon','authenticated')
    AND (privilege.routine_name LIKE '%delivery_fee%'
      OR privilege.routine_name IN('save_backoffice_sales_invoice_draft_core',
        'backoffice_sales_invoice_snapshot','backoffice_sales_order_snapshot'))
  UNION ALL
  SELECT 'delivery_fee_public_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE grantee='anon')=0
      AND count(*) FILTER(WHERE grantee='authenticated')=2 THEN 'PASS' ELSE 'FAIL' END,
    (count(*) FILTER(WHERE grantee='anon')
      +abs(2-count(*) FILTER(WHERE grantee='authenticated')))::bigint,
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE grantee='anon'),
      'authenticatedExecute',count(*) FILTER(WHERE grantee='authenticated'))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='public'
    AND privilege.routine_name IN('save_backoffice_sales_order_draft',
      'save_backoffice_sales_invoice_draft')
    AND privilege.grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'regular_invoice_delivery_fee_mapping',
    CASE WHEN count(*)>0 AND bool_and(mapped.mapping_count=1) THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE mapped.mapping_count<>1)::bigint,
    jsonb_build_object('companies',count(*),'invalidCompanies',
      count(*) FILTER(WHERE mapped.mapping_count<>1))
  FROM (SELECT category.company_id,count(rule.id) mapping_count
    FROM public.transaction_categories category
    LEFT JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
      AND rule.transaction_category_id=category.id
      AND rule.system_key='BACKOFFICE_SALES_INVOICE'
      AND rule.account_function_key='DELIVERY_FEE_REVENUE' AND rule.status='ACTIVE'
    WHERE category.system_key='BACKOFFICE_SALES_INVOICE' AND category.is_active
    GROUP BY category.company_id) mapped
  UNION ALL
  SELECT 'regular_invoice_posting_rule_v3',
    CASE WHEN count(*)>0 AND bool_and(mapped.rule_set_version=3
      AND mapped.line_count=6 AND mapped.delivery_lines=1) THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE mapped.rule_set_version<>3 OR mapped.line_count<>6
      OR mapped.delivery_lines<>1)::bigint,
    jsonb_build_object('approvedSets',count(*),'invalidSets',count(*) FILTER(
      WHERE mapped.rule_set_version<>3 OR mapped.line_count<>6 OR mapped.delivery_lines<>1))
  FROM (SELECT rule_set.id,rule_set.rule_set_version,count(line.id) line_count,
      count(*) FILTER(WHERE line.account_function_key='DELIVERY_FEE_REVENUE'
        AND line.entry_side='CREDIT'
        AND line.amount_expression_key='BACKOFFICE_INVOICE_DELIVERY_FEE') delivery_lines
    FROM public.posting_rule_sets rule_set
    JOIN public.posting_rule_lines line ON line.company_id=rule_set.company_id
      AND line.rule_set_id=rule_set.id
    WHERE rule_set.system_key='BACKOFFICE_SALES_INVOICE' AND rule_set.status='APPROVED'
    GROUP BY rule_set.id,rule_set.rule_set_version) mapped
  UNION ALL
  SELECT 'delivery_fee_system_event_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('eventRows',count(*))
  FROM public.system_events event WHERE event.system_key='BACKOFFICE_SALES_INVOICE'
    AND 'DELIVERY_FEE_REVENUE'=ANY(event.conditional_account_functions)
  UNION ALL
  SELECT 'delivery_fee_finance_runtime_definition',
    CASE WHEN position('DELIVERY_FEE_REVENUE' in definition)>0
      AND position('deliveryFeeAmount' in definition)>0
      AND position('NULLIF(v_event.amounts->>''deliveryFeeAmount'','''')::numeric,0'
        in definition)>0
      AND position('v_expected_credit:=round(v_revenue+v_invoice.tax_total+v_delivery_fee,4);'
        in definition)>0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('DELIVERY_FEE_REVENUE' in definition)>0
      AND position('deliveryFeeAmount' in definition)>0
      AND position('NULLIF(v_event.amounts->>''deliveryFeeAmount'','''')::numeric,0'
        in definition)>0
      AND position('v_expected_credit:=round(v_revenue+v_invoice.tax_total+v_delivery_fee,4);'
        in definition)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('legacyMissingFeeDefaultsToZero',
      position('NULLIF(v_event.amounts->>''deliveryFeeAmount'','''')::numeric,0'
        in definition)>0)
  FROM (SELECT pg_get_functiondef(to_regprocedure(
    'private.post_backoffice_sales_invoice_financial_event_core(uuid,uuid,bigint,uuid)'))
    definition) runtime
  UNION ALL
  SELECT 'sales_order_delivery_fee_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_orders document
  WHERE document.delivery_fee_amount<0
    OR round(document.grand_total,4)<>round(document.grand_total_before_rounding
      +document.rounding_adjustment+document.delivery_fee_amount,4)
    OR document.delivery_fee_amount<COALESCE((SELECT sum(invoice.delivery_fee_amount)
      FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=document.company_id AND invoice.sales_order_id=document.id
        AND invoice.invoice_type='REGULAR' AND invoice.status IN('DRAFT','POSTED')),0)
  UNION ALL
  SELECT 'invoice_delivery_fee_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.delivery_fee_amount<0
    OR (invoice.invoice_type='DOWN_PAYMENT' AND invoice.delivery_fee_amount<>0)
    OR round(invoice.grand_total,4)<>round(invoice.charge_total-invoice.discount_total
      +invoice.tax_total+invoice.delivery_fee_amount-invoice.down_payment_deduction_total,4)
  UNION ALL
  SELECT 'posted_delivery_fee_finance_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoices invoice
  JOIN public.financial_events event ON event.company_id=invoice.company_id
    AND event.id=invoice.financial_event_id
  WHERE invoice.status='POSTED' AND invoice.invoice_type='REGULAR'
    AND (COALESCE(NULLIF(event.amounts->>'deliveryFeeAmount','')::numeric,0)
        <>invoice.delivery_fee_amount
      OR (invoice.delivery_fee_amount>0 AND NOT EXISTS(
        SELECT 1 FROM public.finance_journals journal
        JOIN public.finance_journal_lines line ON line.company_id=journal.company_id
          AND line.journal_id=journal.id
        JOIN public.transaction_account_rules rule ON rule.company_id=invoice.company_id
          AND rule.transaction_category_id=event.transaction_category_id
          AND rule.account_function_key='DELIVERY_FEE_REVENUE'
          AND rule.account_id=line.account_id AND rule.status='ACTIVE'
        WHERE journal.company_id=invoice.company_id
          AND journal.financial_event_id=event.id AND journal.status='POSTED'
        GROUP BY journal.id HAVING round(sum(line.credit-line.debit),4)=invoice.delivery_fee_amount)))
  UNION ALL
  SELECT 'delivery_fee_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'ordersWithFee',(SELECT count(*) FROM public.backoffice_sales_orders
      WHERE delivery_fee_amount>0),
    'draftInvoiceFee',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND delivery_fee_amount>0),
    'postedInvoiceFee',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='POSTED' AND delivery_fee_amount>0),
    'allocatedAmount',(SELECT COALESCE(sum(delivery_fee_amount),0)
      FROM public.backoffice_sales_invoices
      WHERE invoice_type='REGULAR' AND status IN('DRAFT','POSTED')))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;

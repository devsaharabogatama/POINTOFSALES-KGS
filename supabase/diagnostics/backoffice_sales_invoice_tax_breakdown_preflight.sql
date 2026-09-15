-- Read-only preflight for 20260909159000. Isolated Development only.
WITH checks AS (
  SELECT 'tax_breakdown_dependency'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909158000'
  UNION ALL
  SELECT 'tax_breakdown_relation_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name='backoffice_sales_invoice_tax_breakdowns'
  UNION ALL
  SELECT 'tax_breakdown_posted_invoice_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('unexpectedRows',count(*))
  FROM public.backoffice_sales_invoices WHERE status IN('POSTED','REVERSED') OR invoice_no IS NOT NULL
    OR financial_event_id IS NOT NULL OR posted_at IS NOT NULL
  UNION ALL
  SELECT 'regular_tax_snapshot_backfill_readiness',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoice_lines line
  JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=line.company_id
    AND invoice.id=line.invoice_id
  WHERE line.tax_amount>0 AND invoice.invoice_type='REGULAR'
    AND (NULLIF(line.source_snapshot->>'taxRuleId','') IS NULL
      OR NULLIF(line.source_snapshot->>'taxRuleVersion','') IS NULL
      OR NULLIF(line.source_snapshot->>'taxAccountId','') IS NULL
      OR NULLIF(line.source_snapshot->>'taxCode','') IS NULL
      OR NULLIF(line.source_snapshot->>'taxName','') IS NULL
      OR NULLIF(line.source_snapshot->>'taxRatePercent','') IS NULL
      OR NULLIF(line.source_snapshot->>'taxPriceMode','') IS NULL
      OR NULLIF(line.source_snapshot->>'taxCalculationScope','') IS NULL)
  UNION ALL
  SELECT 'dp_tax_snapshot_backfill_readiness',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.invoice_type='DOWN_PAYMENT' AND invoice.tax_total>0 AND
    (invoice.down_payment_basis_total<=0 OR NOT EXISTS(SELECT 1
      FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=invoice.company_id AND line.sales_order_id=invoice.sales_order_id
        AND line.tax_amount>0 AND line.tax_rule_id IS NOT NULL
        AND line.tax_rule_version IS NOT NULL AND line.tax_account_id IS NOT NULL))
  UNION ALL
  SELECT 'tax_snapshot_version_lineage',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  LEFT JOIN public.tax_rule_versions version ON version.company_id=line.company_id
    AND version.tax_rule_id=line.tax_rule_id AND version.rule_version=line.tax_rule_version
  WHERE line.tax_amount>0 AND version.id IS NULL
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'tax_breakdown_backfill_inventory','INFO',0::bigint,jsonb_build_object(
    'draftRegular',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='REGULAR'),
    'draftDownPayment',(SELECT count(*) FROM public.backoffice_sales_invoices
      WHERE status='DRAFT' AND invoice_type='DOWN_PAYMENT'),
    'canceled',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='CANCELED'),
    'invoiceOperations',(SELECT count(*) FROM public.backoffice_sales_invoice_operations))
)
SELECT * FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;

-- Read-only closing verification after migration 20261006140000.
WITH required_relation(name) AS (VALUES
 ('private.backoffice_invoice_revision_preparations'),('private.backoffice_invoice_revisions'),
 ('private.backoffice_invoice_revision_lines'),('private.backoffice_invoice_revision_settlement_attributions')
), missing_relation AS (
 SELECT name FROM required_relation WHERE to_regclass(name) IS NULL
), required_routine(name) AS (VALUES
 ('private.backoffice_invoice_revision_amount_preview(uuid,uuid,bigint,bigint,jsonb)'),
 ('private.backoffice_invoice_revision_date_preview(uuid,uuid,bigint,date)'),
 ('private.prepare_backoffice_invoice_revision(jsonb)'),
 ('private.plan_backoffice_invoice_revision_execution(uuid)'),
 ('private.plan_backoffice_invoice_revision_journals(uuid)'),
 ('private.execute_backoffice_invoice_revision(uuid)'),
 ('private.backoffice_invoice_effective_identity(uuid,uuid,date)'),
 ('public.post_backoffice_invoice_revision(jsonb)'),
 ('public.get_backoffice_invoice_revision_context(uuid)'),
 ('public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid)'),
 ('public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)')
), missing_routine AS (
 SELECT name FROM required_routine WHERE to_regprocedure(name) IS NULL
), invalid_history AS (
 SELECT revision.company_id,revision.invoice_id,revision.revision_no
 FROM private.backoffice_invoice_revisions revision
 LEFT JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=revision.company_id AND invoice.id=revision.invoice_id
 WHERE invoice.id IS NULL OR revision.revision_no<=0 OR revision.payable_delta IS NULL
), invalid_schedule AS (
 SELECT schedule.company_id,schedule.invoice_id,schedule.installment_no
 FROM public.backoffice_sales_invoice_receivable_schedules schedule
 WHERE EXISTS(SELECT 1 FROM private.backoffice_invoice_revisions revision
   WHERE revision.company_id=schedule.company_id AND revision.invoice_id=schedule.invoice_id)
 GROUP BY schedule.company_id,schedule.invoice_id,schedule.installment_no,schedule.amount_due
 HAVING schedule.amount_due<0
), checks AS (
 SELECT 'invoice_revision_migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
   abs(count(*)-1) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
 FROM private.kgs_schema_migrations WHERE version='20261006140000'
 UNION ALL SELECT 'invoice_revision_relation_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
   count(*),jsonb_build_object('missing',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb)) FROM missing_relation
 UNION ALL SELECT 'invoice_revision_routine_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
   count(*),jsonb_build_object('missing',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb)) FROM missing_routine
 UNION ALL SELECT 'invoice_revision_permission_contract',
   CASE WHEN has_function_privilege('authenticated','public.post_backoffice_invoice_revision(jsonb)','EXECUTE')
     AND has_function_privilege('authenticated','public.get_backoffice_invoice_revision_context(uuid)','EXECUTE')
     AND NOT has_function_privilege('anon','public.post_backoffice_invoice_revision(jsonb)','EXECUTE')
     AND NOT has_function_privilege('authenticated','private.execute_backoffice_invoice_revision(uuid)','EXECUTE')
     THEN 'PASS' ELSE 'FAIL' END,
   CASE WHEN has_function_privilege('authenticated','public.post_backoffice_invoice_revision(jsonb)','EXECUTE')
     AND has_function_privilege('authenticated','public.get_backoffice_invoice_revision_context(uuid)','EXECUTE')
     AND NOT has_function_privilege('anon','public.post_backoffice_invoice_revision(jsonb)','EXECUTE')
     AND NOT has_function_privilege('authenticated','private.execute_backoffice_invoice_revision(uuid)','EXECUTE')
     THEN 0 ELSE 1 END,jsonb_build_object('publicAuthenticated',true,'privateAuthenticated',false)
 UNION ALL SELECT 'invoice_revision_history_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
   count(*),jsonb_build_object('invalidRows',count(*)) FROM invalid_history
 UNION ALL SELECT 'invoice_revision_schedule_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
   count(*),jsonb_build_object('invalidRows',count(*)) FROM invalid_schedule
 UNION ALL SELECT 'invoice_revision_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
   count(*),jsonb_build_object('rows',count(*)) FROM public.finance_posting_queue_runs
   WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'invoice_revision_runtime_inventory','INFO',0,
   jsonb_build_object('revisions',count(*),'invoices',count(DISTINCT invoice_id),'journalRows',
     (SELECT count(*) FROM public.finance_journals journal WHERE journal.source_type='backoffice_invoice_revisions'))
   FROM private.backoffice_invoice_revisions
 UNION ALL SELECT 'invoice_revision_business_boundary','INFO',0,jsonb_build_object(
   'enabledCompanies',ARRAY['KMS','LSM','SMS'],
   'editable',ARRAY['billing customer','invoice date','unit price','line discount'],
   'immutable',ARRAY['source Invoice','SO','DO','product','quantity','UOM','Stock','FIFO','COGS'],
   'separateWorkflows',ARRAY['payment error correction','actual refund payout'])
)
SELECT * FROM checks ORDER BY check_name;

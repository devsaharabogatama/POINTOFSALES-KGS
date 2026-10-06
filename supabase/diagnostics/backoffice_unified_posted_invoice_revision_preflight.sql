-- Read-only preflight. Run the whole statement and stop on any BLOCKER.
WITH required(version) AS (VALUES
 ('20260909161000'),('20260911160000'),('20260911162000'),('20260911163000'),
 ('20260917131000'),('20260917150000'),('20260925100000'),('20260928110000'),('20260929130000')
), dependency AS (
 SELECT required.version FROM required LEFT JOIN private.kgs_schema_migrations installed
   ON installed.version=required.version WHERE installed.version IS NULL
), target_company(id,expected_name) AS (VALUES
 ('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,'Khadijah Muda Sejahtera'),
 ('07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'Latorti Sari Median'),
 ('809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid,'Smart Muda Solusi')
), invalid_company AS (
 SELECT target.* FROM target_company target LEFT JOIN public.companies company ON company.id=target.id
 WHERE company.id IS NULL OR company.company_name<>target.expected_name OR company.status<>'ACTIVE'
), collision(name) AS (VALUES
 ('private.backoffice_invoice_revision_preparations'),('private.backoffice_invoice_revisions'),
 ('private.backoffice_invoice_revision_lines'),('private.backoffice_invoice_revision_settlement_attributions'),
 ('public.post_backoffice_invoice_revision(jsonb)'),('public.get_backoffice_invoice_revision_context(uuid)'),
 ('private.backoffice_invoice_effective_total_before_unified_revision(uuid,uuid,date)'),
 ('private.backoffice_invoice_effective_entered_unit_price_before_unified_revision(uuid,uuid)'),
 ('private.backoffice_invoice_effective_line_amounts_before_unified_revision(uuid,uuid)'),
 ('public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid)'),
 ('public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)')
), existing_collision AS (
 SELECT name FROM collision WHERE CASE WHEN position('(' IN name)>0
   THEN to_regprocedure(name) IS NOT NULL ELSE to_regclass(name) IS NOT NULL END
), runtime(signature,expected_digest) AS (VALUES
 ('private.backoffice_invoice_effective_total(uuid,uuid,date)','0a64be9b35ac9fba3db3abcd9ab38fad'),
 ('private.backoffice_invoice_effective_entered_unit_price(uuid,uuid)','2b9cc8a191cb110e5dc31410a6896e40'),
 ('private.backoffice_invoice_effective_line_amounts(uuid,uuid)','82f8ce5bb1b4edf39a53cbe5f191666c'),
 ('public.get_backoffice_sales_invoice_ui(uuid)','835f1723cc9b19db2675f40276ef5cff'),
 ('public.get_backoffice_sales_invoice_payment_context(uuid)','b8145d8ca6de47227d8a740281fe5238'),
 ('public.get_finance_ar_aging(date,uuid,uuid)','5b5f98c00338a5aea20ca70d2a783060'),
 ('public.get_finance_customer_statement(uuid,date,date,uuid)','202555b9f00a53e8fd4f05bc9e77bcc8'),
 ('public.export_sales_documents(date,date)','66d00e34c458d0ff6dc9fd24374743a2'),
 ('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)','70ea76646c02618553ab2bc752ae1b33'),
 ('private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)','a2d1fbd923bc91bbac81cb482198d46b')
), invalid_runtime AS (
 SELECT signature,expected_digest,
   CASE WHEN to_regprocedure(signature) IS NULL THEN NULL
     ELSE md5(pg_get_functiondef(to_regprocedure(signature))) END live_digest
 FROM runtime WHERE to_regprocedure(signature) IS NULL
   OR md5(pg_get_functiondef(to_regprocedure(signature)))<>expected_digest
), checks AS (
 SELECT 'invoice_revision_dependency_ledger' check_name,
   CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,count(*) violation_rows,
   jsonb_build_object('missing',COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb)) details FROM dependency
 UNION ALL SELECT 'invoice_revision_target_company_identity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*),jsonb_build_object('invalid',COALESCE(jsonb_agg(to_jsonb(invalid_company)),'[]'::jsonb)) FROM invalid_company
 UNION ALL SELECT 'invoice_revision_object_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*),jsonb_build_object('existing',COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb)) FROM existing_collision
 UNION ALL SELECT 'invoice_revision_runtime_anchor',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*),jsonb_build_object('invalid',COALESCE(jsonb_agg(to_jsonb(invalid_runtime) ORDER BY signature),'[]'::jsonb)) FROM invalid_runtime
 UNION ALL SELECT 'invoice_revision_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*),jsonb_build_object('rows',count(*)) FROM public.finance_posting_queue_runs
   WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
 UNION ALL SELECT 'invoice_revision_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*),jsonb_build_object('rows',count(*)) FROM public.pos_offline_sale_submissions
   WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
 UNION ALL SELECT 'invoice_revision_migration_absence',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
   count(*),jsonb_build_object('version','20261006140000','ledgerRows',count(*))
   FROM private.kgs_schema_migrations WHERE version='20261006140000'
 UNION ALL SELECT 'invoice_revision_runtime_inventory','INFO',0,
   jsonb_build_object('eligiblePostedRegularInvoices',count(*),
     'targetCompanies',count(DISTINCT invoice.company_id))
   FROM public.backoffice_sales_invoices invoice WHERE invoice.status='POSTED' AND invoice.invoice_type='REGULAR'
     AND invoice.company_id IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
       '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid)
)
SELECT * FROM checks ORDER BY check_name;

-- ACP-7 preflight: custom-permission security closure and pre-deploy return.
-- SAFETY: one SELECT statement; aggregate metadata only; no identity, payload,
-- DDL, DML, temporary object, or function execution with side effects.

WITH required_versions(version) AS (VALUES
  ('20260812140000'),('20260812150000'),('20260812160000'),
  ('20260812170000'),('20260812180000'),('20260812190000'),
  ('20260812200000'),('20260812210000'),('20260812220000'),
  ('20260812230000'),('20260813000000'),('20260813010000'),
  ('20260813020000'),('20260813030000'),('20260813040000'),
  ('20260813050000'),('20260813060000'),('20260813070000'),
  ('20260813080000'),('20260813090000'),('20260813100000'),
  ('20260813110000'),('20260813120000'),('20260813130000'),
  ('20260813140000'),('20260813150000'),('20260825130000'),
  ('20260825131000')
), expected_enforced(permission_key) AS (VALUES
  ('inventory.master_data'),('inventory.products'),
  ('inventory.stock_real'),('inventory.stock_movements'),
  ('inventory.stock_transfers'),('inventory.stock_adjustments'),
  ('inventory.stock_opnames'),('inventory.opening_stock'),
  ('inventory.minimum_stock'),('contacts.customers'),('contacts.suppliers'),
  ('inventory.delivery_documents'),
  ('purchase.supplier_orders'),('purchase.goods_receipts'),
  ('purchase.purchase_returns'),
  ('sales.sales_documents'),('sales.pricelists'),('sales.bundles'),
  ('sales.sales_returns'),('finance.expenses'),('finance.cash_deposits'),
  ('finance.deposit_variances'),('finance.customer_balances'),
  ('finance.supplier_invoices'),('finance.supplier_payments'),
  ('finance.payment_methods')
), required_roles(role_code) AS (VALUES
  ('COMPANY_OWNER'),('COMPANY_ADMIN'),('FINANCE'),('ACCOUNTING'),
  ('STORE_MANAGER'),('WAREHOUSE_ADMIN'),('CASHIER')
), protected_relations(relation_name) AS (VALUES
  ('company_memberships'),('store_memberships'),
  ('user_company_permission_overrides'),('user_company_permission_audit'),
  ('product_stocks'),('product_batches'),('stock_movements'),
  ('sales_headers'),('sales_details'),('sales_payments'),
  ('financial_events'),('finance_journals'),('finance_journal_lines')
), active_memberships AS (
  SELECT membership.company_id,membership.user_id,membership.role_code
  FROM public.company_memberships membership
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  JOIN public.companies company ON company.id=membership.company_id
  WHERE membership.status='ACTIVE' AND company.status='ACTIVE'
), movement_totals AS (
  SELECT movement.company_id,movement.product_id,movement.warehouse_id,
    COALESCE(sum(movement.qty_change) FILTER(
      WHERE movement.movement_status='POSTED'),0) quantity
  FROM public.stock_movements movement
  GROUP BY movement.company_id,movement.product_id,movement.warehouse_id
), fifo_totals AS (
  SELECT batch.company_id,batch.product_id,batch.warehouse_id,
    COALESCE(sum(batch.qty_remaining),0) quantity
  FROM public.product_batches batch
  GROUP BY batch.company_id,batch.product_id,batch.warehouse_id
), stock_keys AS (
  SELECT company_id,product_id,warehouse_id FROM public.product_stocks
  UNION SELECT company_id,product_id,warehouse_id FROM movement_totals
  UNION SELECT company_id,product_id,warehouse_id FROM fifo_totals
), stock_reconciliation AS (
  SELECT key.company_id,key.product_id,key.warehouse_id,
    COALESCE(stock.stock_qty,0) stock_qty,
    COALESCE(movement.quantity,0) movement_qty,
    COALESCE(fifo.quantity,0) fifo_qty
  FROM stock_keys key
  LEFT JOIN public.product_stocks stock USING(company_id,product_id,warehouse_id)
  LEFT JOIN movement_totals movement USING(company_id,product_id,warehouse_id)
  LEFT JOIN fifo_totals fifo USING(company_id,product_id,warehouse_id)
), checks AS (
  SELECT 'acp_enforcement_migration_chain'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE ledger.version IS NULL)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      required.version ORDER BY required.version) FILTER(
        WHERE ledger.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations ledger USING(version)

  UNION ALL SELECT 'expected_permission_enforcement',
    CASE WHEN count(*) FILTER(WHERE catalog.permission_key IS NULL
      OR catalog.enforcement_status<>'ENFORCED')=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'enforced',count(*) FILTER(
      WHERE catalog.enforcement_status='ENFORCED'),'missing_or_not_enforced',
      COALESCE(jsonb_agg(expected.permission_key ORDER BY expected.permission_key)
        FILTER(WHERE catalog.permission_key IS NULL
          OR catalog.enforcement_status<>'ENFORCED'),'[]'::JSONB))
  FROM expected_enforced expected
  LEFT JOIN public.access_permission_catalog catalog USING(permission_key)

  UNION ALL SELECT 'unexpected_permission_enforcement',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('permission_count',count(*),'permission_keys',COALESCE(
      jsonb_agg(catalog.permission_key ORDER BY catalog.permission_key),
      '[]'::JSONB))
  FROM public.access_permission_catalog catalog
  WHERE catalog.enforcement_status='ENFORCED' AND NOT EXISTS(
    SELECT 1 FROM expected_enforced expected
    WHERE expected.permission_key=catalog.permission_key)

  UNION ALL SELECT 'permission_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN active_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id
  WHERE membership.user_id IS NULL

  UNION ALL SELECT 'permission_override_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  JOIN public.access_permission_catalog catalog
    ON catalog.permission_key=override_row.permission_key
  WHERE override_row.restriction_preset NOT IN(
      'LIHAT_SAJA','OPERASIONAL','TANPA_AKSES')
     OR override_row.master_version<=0 OR NOT catalog.is_customizable

  UNION ALL SELECT 'permission_audit_immutable_trigger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('trigger_rows',count(*))
  FROM pg_trigger trigger
  JOIN pg_class class ON class.oid=trigger.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=class.relnamespace
  WHERE namespace.nspname='public'
    AND class.relname='user_company_permission_audit'
    AND trigger.tgname='trg_acp_guard_permission_history'
    AND trigger.tgenabled<>'D' AND NOT trigger.tgisinternal

  UNION ALL SELECT 'permission_admin_browser_boundary',
    CASE WHEN NOT has_table_privilege('authenticated',
        'public.user_company_permission_overrides','INSERT,UPDATE,DELETE')
      AND NOT has_table_privilege('authenticated',
        'public.user_company_permission_audit','INSERT,UPDATE,DELETE')
      AND has_function_privilege('authenticated',
        'public.list_user_permission_profile(uuid,uuid)','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.save_user_permission_override(uuid,uuid,text,text,bigint)',
        'EXECUTE') THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('override_direct_write',has_table_privilege(
      'authenticated','public.user_company_permission_overrides',
      'INSERT,UPDATE,DELETE'),'audit_direct_write',has_table_privilege(
      'authenticated','public.user_company_permission_audit',
      'INSERT,UPDATE,DELETE'))

  UNION ALL SELECT 'protected_browser_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege('authenticated',
      format('public.%I',relation_name),'INSERT,UPDATE,DELETE'))=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(
      relation_name ORDER BY relation_name) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),
      'INSERT,UPDATE,DELETE')),'[]'::JSONB))
  FROM protected_relations

  UNION ALL SELECT 'active_company_context_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('row_count',count(*))
  FROM public.user_active_company_contexts context
  LEFT JOIN public.profiles profile ON profile.id=context.user_id
  LEFT JOIN public.companies company ON company.id=context.company_id
  LEFT JOIN active_memberships membership
    ON membership.company_id=context.company_id
   AND membership.user_id=context.user_id
  WHERE profile.id IS NULL OR company.id IS NULL OR company.status<>'ACTIVE'
    OR (profile.role<>'super_admin'::public.user_role
      AND membership.user_id IS NULL)

  UNION ALL SELECT 'two_company_uat_scope',
    CASE WHEN count(*)>=2 THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('active_companies',count(*),'required',2)
  FROM public.companies WHERE status='ACTIVE'

  UNION ALL SELECT 'role_uat_coverage',
    CASE WHEN count(*) FILTER(WHERE actual.role_code IS NULL)=0
      THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(
      required.role_code ORDER BY required.role_code) FILTER(
      WHERE actual.role_code IS NULL),'[]'::JSONB))
  FROM required_roles required LEFT JOIN(
    SELECT DISTINCT role_code FROM active_memberships
  ) actual USING(role_code)

  UNION ALL SELECT 'regular_multi_company_uat_identity',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('eligible_users',count(*),'required',1)
  FROM (SELECT membership.user_id FROM active_memberships membership
    JOIN public.profiles profile ON profile.id=membership.user_id
    WHERE profile.role<>'super_admin'::public.user_role
    GROUP BY membership.user_id
    HAVING count(DISTINCT membership.company_id)>=2) eligible

  UNION ALL SELECT 'multi_company_distinct_override_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('eligible_users',count(*),'required',1)
  FROM (SELECT override_row.user_id,override_row.permission_key
    FROM public.user_company_permission_overrides override_row
    GROUP BY override_row.user_id,override_row.permission_key
    HAVING count(DISTINCT override_row.company_id)>=2
      AND count(DISTINCT override_row.restriction_preset)>=2) fixture

  UNION ALL SELECT 'nonterminal_background_work',
    CASE WHEN sum(row_count)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('import_jobs',max(row_count) FILTER(WHERE kind='import'),
      'offline_submissions',max(row_count) FILTER(WHERE kind='offline'),
      'finance_queue_runs',max(row_count) FILTER(WHERE kind='finance'))
  FROM (SELECT 'import' kind,count(*) row_count FROM public.master_import_jobs
      WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')
    UNION ALL SELECT 'offline',count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
    UNION ALL SELECT 'finance',count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) work

  UNION ALL SELECT 'stock_balance_movement_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('pair_count',count(*))
  FROM stock_reconciliation reconciliation
  WHERE reconciliation.stock_qty<>reconciliation.movement_qty
     OR reconciliation.stock_qty<>reconciliation.fifo_qty

  UNION ALL SELECT 'posted_journal_balance_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('journal_count',count(*))
  FROM public.finance_journals journal
  WHERE journal.status='POSTED' AND abs(COALESCE((SELECT
    sum(line.debit-line.credit) FROM public.finance_journal_lines line
    WHERE line.company_id=journal.company_id
      AND line.journal_id=journal.id),0))>0.0001

  UNION ALL SELECT 'acp7_authenticated_closure_matrix','REVIEW',
    jsonb_build_object('required_browser_checks',jsonb_build_array(
      'role baseline versus LIHAT_SAJA, OPERASIONAL and TANPA_AKSES',
      'Home, module landing, Fast Link, direct URL, API and RPC parity',
      'different override for one regular user in Company A and Company B',
      'feature OFF, inactive membership and active-Company mismatch denial',
      'revoke while session is active plus hard refresh and stale-tab denial',
      'exact retry, optimistic conflict and immutable permission audit'))

  UNION ALL SELECT 'client_build_and_environment_scope','DEFERRED',
    jsonb_build_object('reason','requires local build and authenticated browser',
      'required_external_checks',jsonb_build_array(
        'Backoffice lint and production build','PWA lint and production build',
        'Supabase Auth redirect allowlist','client bundle contains no secret',
        'Vercel Preview environment and domain smoke'))

  UNION ALL SELECT 'permission_runtime_inventory','INFO',jsonb_build_object(
    'catalog_rows',(SELECT count(*) FROM public.access_permission_catalog),
    'enforced_rows',(SELECT count(*) FROM public.access_permission_catalog
      WHERE enforcement_status='ENFORCED'),
    'override_rows',(SELECT count(*)
      FROM public.user_company_permission_overrides),
    'audit_rows',(SELECT count(*) FROM public.user_company_permission_audit),
    'active_companies',(SELECT count(*) FROM public.companies
      WHERE status='ACTIVE'),
    'active_memberships',(SELECT count(*) FROM active_memberships))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'REVIEW' THEN 3 WHEN 'PASS' THEN 4 WHEN 'DEFERRED' THEN 5 ELSE 6 END,
  check_name;

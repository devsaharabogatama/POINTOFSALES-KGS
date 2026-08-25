-- PRD-1 preflight: full pre-deploy closing readiness before Vercel Preview.
-- SAFETY: one SELECT statement; aggregate counts only; no names or payloads.

WITH required_versions(version) AS (
    VALUES
        ('20260811100000'), -- human-readable Finance IDs
        ('20260811110000'), -- Company branding foundation
        ('20260811130000'), -- Invoice and Surat Jalan
        ('20260811140000'), -- Delivery fee foundation
        ('20260811143000'), -- shared POST repricing fix
        ('20260811150000'), -- explicit Delivery-fee Return
        ('20260812120000'), -- custom permission foundation
        ('20260812140000'),('20260812150000'),('20260812160000'),
        ('20260812170000'),('20260812180000'),('20260812190000'),
        ('20260812200000'),('20260812210000'),('20260812220000'),
        ('20260812230000'),('20260813000000'),('20260813010000'),
        ('20260813020000'),('20260813030000'),('20260813040000'),
        ('20260813050000'),('20260813060000'),('20260813070000'),
        ('20260813080000'),('20260813090000'),('20260813100000'),
        ('20260813110000'),('20260813120000'),('20260813130000'),
        ('20260813140000'), -- explicit per-Company access lifecycle
        ('20260813150000'), -- Inventory-owned Surat Jalan authority
        ('20260818090000'), -- guarded unused UOM/Category cleanup
        ('20260819150000'), -- Customer master import/export
        ('20260819160000'), -- additive Product-UOM import/export
        ('20260819170000'), -- negative Stock Session replenishment request
        ('20260821100000'), -- contextual Product-UOM template and job cancellation
        ('20260821110000'), -- Product-UOM partial validation restore
        ('20260825130000'), -- Backoffice Goods Receipt channel
        ('20260825131000') -- Backoffice Goods Receipt workspace fix
), expected_enforced_permissions(permission_key) AS (
    VALUES
        ('inventory.master_data'),('inventory.products'),
        ('inventory.stock_real'),('inventory.stock_movements'),
        ('inventory.stock_transfers'),('inventory.stock_adjustments'),
        ('inventory.stock_opnames'),('inventory.opening_stock'),
        ('inventory.minimum_stock'),('contacts.customers'),
        ('inventory.delivery_documents'),
        ('contacts.suppliers'),('purchase.supplier_orders'),
        ('purchase.goods_receipts'),
        ('purchase.purchase_returns'),('sales.sales_documents'),
        ('sales.pricelists'),('sales.bundles'),('sales.sales_returns'),
        ('finance.expenses'),('finance.cash_deposits'),
        ('finance.deposit_variances'),('finance.customer_balances'),
        ('finance.supplier_invoices'),('finance.supplier_payments'),
        ('finance.payment_methods')
), required_company_roles(role_code) AS (
    VALUES
        ('COMPANY_OWNER'),('COMPANY_ADMIN'),('FINANCE'),('ACCOUNTING'),
        ('WAREHOUSE_ADMIN')
), required_store_roles(role_code) AS (
    VALUES ('STORE_MANAGER'),('CASHIER')
), active_companies AS (
    SELECT company.id
    FROM public.companies company
    WHERE company.status='ACTIVE'
), movement_totals AS (
    SELECT movement.company_id,movement.product_id,movement.warehouse_id,
        COALESCE(sum(movement.qty_change) FILTER(
            WHERE movement.movement_status='POSTED'
        ),0) movement_qty
    FROM public.stock_movements movement
    GROUP BY movement.company_id,movement.product_id,movement.warehouse_id
), fifo_totals AS (
    SELECT batch.company_id,batch.product_id,batch.warehouse_id,
        COALESCE(sum(batch.qty_remaining),0) fifo_qty
    FROM public.product_batches batch
    GROUP BY batch.company_id,batch.product_id,batch.warehouse_id
), stock_keys AS (
    SELECT stock.company_id,stock.product_id,stock.warehouse_id
    FROM public.product_stocks stock
    UNION
    SELECT movement.company_id,movement.product_id,movement.warehouse_id
    FROM movement_totals movement
    UNION
    SELECT fifo.company_id,fifo.product_id,fifo.warehouse_id
    FROM fifo_totals fifo
), stock_reconciliation AS (
    SELECT key.company_id,key.product_id,key.warehouse_id,
        COALESCE(stock.stock_qty,0) stock_qty,
        COALESCE(movement.movement_qty,0) movement_qty,
        COALESCE(fifo.fifo_qty,0) fifo_qty
    FROM stock_keys key
    LEFT JOIN public.product_stocks stock
      ON stock.company_id=key.company_id
     AND stock.product_id=key.product_id
     AND stock.warehouse_id=key.warehouse_id
    LEFT JOIN movement_totals movement
      ON movement.company_id=key.company_id
     AND movement.product_id=key.product_id
     AND movement.warehouse_id=key.warehouse_id
    LEFT JOIN fifo_totals fifo
      ON fifo.company_id=key.company_id
     AND fifo.product_id=key.product_id
     AND fifo.warehouse_id=key.warehouse_id
), posted_sales AS (
    SELECT sale.*
    FROM public.sales_headers sale
    WHERE sale.document_status='POSTED'
), critical_relations(relation_name) AS (
    VALUES
        ('sales_headers'),('sales_details'),('sales_payments'),
        ('sales_return_documents'),('sales_invoice_snapshots'),
        ('sales_delivery_documents'),('product_stocks'),('product_batches'),
        ('stock_movements'),('financial_events'),('finance_journals'),
        ('finance_journal_lines')
), checks AS (
    SELECT 'prd_required_migration_chain'::TEXT check_name,
        CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(required.version ORDER BY required.version)
                FILTER(WHERE migration.version IS NULL),'[]'::JSONB)
        ) details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL
    SELECT 'prd_permission_enforcement_chain',
        CASE WHEN count(*) FILTER(
            WHERE catalog.permission_key IS NULL
               OR catalog.enforcement_status<>'ENFORCED'
        )=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'enforced',count(*) FILTER(
                WHERE catalog.enforcement_status='ENFORCED'
            ),
            'missing_or_not_enforced',COALESCE(jsonb_agg(
                expected.permission_key ORDER BY expected.permission_key
            ) FILTER(
                WHERE catalog.permission_key IS NULL
                   OR catalog.enforcement_status<>'ENFORCED'
            ),'[]'::JSONB)
        )
    FROM expected_enforced_permissions expected
    LEFT JOIN public.access_permission_catalog catalog
      ON catalog.permission_key=expected.permission_key

    UNION ALL
    SELECT 'prd_permission_override_tenant_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.user_company_permission_overrides override_row
    LEFT JOIN public.company_memberships membership
      ON membership.company_id=override_row.company_id
     AND membership.user_id=override_row.user_id
     AND membership.status='ACTIVE'
    WHERE membership.id IS NULL

    UNION ALL
    SELECT 'prd_regular_multi_company_override_fixture',
        CASE WHEN count(*)>0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('eligible_users',count(*),'required',1)
    FROM (
        SELECT override_row.user_id,override_row.permission_key
        FROM public.user_company_permission_overrides override_row
        JOIN public.company_memberships membership
          ON membership.company_id=override_row.company_id
         AND membership.user_id=override_row.user_id
         AND membership.status='ACTIVE'
        JOIN public.profiles profile ON profile.id=override_row.user_id
        WHERE profile.role<>'super_admin'::public.user_role
        GROUP BY override_row.user_id,override_row.permission_key
        HAVING count(DISTINCT override_row.company_id)>=2
           AND count(DISTINCT override_row.restriction_preset)>=2
    ) eligible

    UNION ALL
    SELECT 'two_company_uat_scope',
        CASE WHEN count(*)>=2 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'active_companies',count(*),
            'required_for_uat',2,
            'companies_to_provision',GREATEST(2-count(*),0)
        )
    FROM active_companies

    UNION ALL
    SELECT 'super_admin_uat_identity',
        CASE WHEN count(*)>0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('linked_super_admins',count(*))
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role

    UNION ALL
    SELECT 'company_role_uat_coverage',
        CASE WHEN count(*) FILTER(WHERE membership.role_code IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(required.role_code ORDER BY required.role_code)
                FILTER(WHERE membership.role_code IS NULL),'[]'::JSONB)
        )
    FROM required_company_roles required
    LEFT JOIN (
        SELECT DISTINCT membership.role_code
        FROM public.company_memberships membership
        JOIN auth.users auth_user ON auth_user.id=membership.user_id
        WHERE membership.status='ACTIVE'
    ) membership ON membership.role_code=required.role_code

    UNION ALL
    SELECT 'store_role_uat_coverage',
        CASE WHEN count(*) FILTER(WHERE membership.role_code IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(required.role_code ORDER BY required.role_code)
                FILTER(WHERE membership.role_code IS NULL),'[]'::JSONB)
        )
    FROM required_store_roles required
    LEFT JOIN (
        SELECT DISTINCT membership.role_code
        FROM public.store_memberships membership
        JOIN auth.users auth_user ON auth_user.id=membership.user_id
        WHERE membership.status='ACTIVE'
    ) membership ON membership.role_code=required.role_code

    UNION ALL
    SELECT 'active_membership_auth_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM (
        SELECT membership.user_id
        FROM public.company_memberships membership
        LEFT JOIN auth.users auth_user ON auth_user.id=membership.user_id
        WHERE membership.status='ACTIVE' AND auth_user.id IS NULL
        UNION ALL
        SELECT membership.user_id
        FROM public.store_memberships membership
        LEFT JOIN auth.users auth_user ON auth_user.id=membership.user_id
        WHERE membership.status='ACTIVE' AND auth_user.id IS NULL
    ) invalid_membership

    UNION ALL
    SELECT 'active_company_operational_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('company_count',count(*))
    FROM active_companies company
    WHERE NOT EXISTS(
        SELECT 1 FROM public.stores store
        WHERE store.company_id=company.id AND store.status='ACTIVE'
    ) OR NOT EXISTS(
        SELECT 1 FROM public.pos_terminals terminal
        JOIN public.stores store
          ON store.company_id=terminal.company_id AND store.id=terminal.store_id
        WHERE terminal.company_id=company.id AND terminal.status='ACTIVE'
          AND store.status='ACTIVE'
    ) OR NOT EXISTS(
        SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=company.id AND warehouse.is_active
          AND warehouse.is_sale_source
    )

    UNION ALL
    SELECT 'active_company_master_fixture_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('company_count',count(*))
    FROM active_companies company
    WHERE NOT EXISTS(
        SELECT 1 FROM public.products product
        WHERE product.company_id=company.id AND product.is_active
    ) OR NOT EXISTS(
        SELECT 1 FROM public.customers customer
        WHERE customer.company_id=company.id AND customer.is_active
    ) OR NOT EXISTS(
        SELECT 1 FROM public.payment_methods method
        WHERE method.company_id=company.id AND method.is_active
    )

    UNION ALL
    SELECT 'nonterminal_import_jobs',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('job_count',count(*),'companies',count(DISTINCT company_id))
    FROM public.master_import_jobs
    WHERE status NOT IN ('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')

    UNION ALL
    SELECT 'nonterminal_offline_submissions',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('submission_count',count(*),'companies',count(DISTINCT company_id))
    FROM public.pos_offline_sale_submissions
    WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')

    UNION ALL
    SELECT 'active_finance_posting_queue',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('run_count',count(*))
    FROM public.finance_posting_queue_runs run
    WHERE run.status IN ('PREVIEWED','APPROVED','PROCESSING')

    UNION ALL
    SELECT 'stock_balance_movement_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation reconciliation
    WHERE reconciliation.stock_qty<>reconciliation.movement_qty

    UNION ALL
    SELECT 'stock_balance_fifo_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation reconciliation
    WHERE reconciliation.stock_qty<>reconciliation.fifo_qty

    UNION ALL
    SELECT 'posted_journal_balance_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals journal
    WHERE journal.status='POSTED' AND abs(
        COALESCE((SELECT sum(line.debit-line.credit)
            FROM public.finance_journal_lines line
            WHERE line.company_id=journal.company_id
              AND line.journal_id=journal.id),0)
    )>0.0001

    UNION ALL
    SELECT 'posted_sale_invoice_snapshot_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM posted_sales sale
    LEFT JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    WHERE invoice.id IS NULL

    UNION ALL
    SELECT 'delivery_sale_document_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM posted_sales sale
    LEFT JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
    WHERE sale.fulfillment_mode='DELIVERY'
      AND (delivery.id IS NULL OR sale.sj_no IS DISTINCT FROM delivery.delivery_no)

    UNION ALL
    SELECT 'posted_sale_single_financial_event',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM (
        SELECT sale.company_id,sale.id,count(event.id) event_count
        FROM posted_sales sale
        LEFT JOIN public.financial_events event
          ON event.company_id=sale.company_id
         AND event.source_table='sales_headers'
         AND event.source_id=sale.id
         AND event.event_type='SALE_POSTED'::public.event_type
        GROUP BY sale.company_id,sale.id
        HAVING count(event.id)<>1
    ) invalid_sale

    UNION ALL
    SELECT 'delivery_fee_return_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('document_count',count(*))
    FROM public.sales_return_documents document
    WHERE document.status='POSTED' AND (
        document.delivery_fee_refund_amount<0
        OR document.delivery_fee_refund_amount>
            document.source_delivery_fee_amount_snapshot
        OR (document.delivery_fee_refund_requested
            AND document.delivery_fee_refund_amount=0)
        OR (NOT document.delivery_fee_refund_requested
            AND document.delivery_fee_refund_amount<>0)
    )

    UNION ALL
    SELECT 'browser_critical_write_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'writable_relations',COALESCE(jsonb_agg(relation_name ORDER BY relation_name),
                '[]'::JSONB)
        )
    FROM critical_relations
    WHERE has_table_privilege(
        'authenticated','public.'||relation_name,'INSERT,UPDATE,DELETE'
    )

    UNION ALL
    SELECT 'company_branding_uat_scope','INFO',jsonb_build_object(
        'active_companies',(SELECT count(*) FROM active_companies),
        'branding_profiles',count(*),
        'companies_with_logo',count(*) FILTER(WHERE logo_object_path IS NOT NULL),
        'policy','Logo is optional, two-Company replace/remove isolation remains manual UAT'
    )
    FROM public.company_branding_profiles

    UNION ALL
    SELECT 'open_document_inventory','INFO',jsonb_build_object(
        'sale_drafts',(SELECT count(*) FROM public.sales_headers
            WHERE document_status='DRAFT'),
        'return_drafts',(SELECT count(*) FROM public.sales_return_documents
            WHERE status='DRAFT'),
        'open_cashier_sessions',(SELECT count(*) FROM public.cashier_sessions
            WHERE status='OPEN'::public.session_status)
    )

    UNION ALL
    SELECT 'finance_hold_boundary','DEFERRED',jsonb_build_object(
        'hold_events',count(*),
        'event_contracts',count(DISTINCT (event_type,source_table)),
        'reason','HOLD contracts remain G6-controlled and are not processed by PRD-1'
    )
    FROM public.financial_events
    WHERE status='HOLD'::public.event_status

    UNION ALL
    SELECT 'vercel_environment_scope','INFO',jsonb_build_object(
        'required_external_checks',jsonb_build_array(
            'Preview project and domains',
            'Supabase Auth redirect allowlist',
            'server-only secrets absent from client bundle',
            'Storage CORS and branding cache',
            'Backoffice and PWA Preview smoke'
        ),
        'reason','Environment and browser checks cannot be proven by database SQL'
    )
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2 WHEN 'REVIEW' THEN 3
    WHEN 'PASS' THEN 4 WHEN 'DEFERRED' THEN 5 ELSE 6 END,check_name;

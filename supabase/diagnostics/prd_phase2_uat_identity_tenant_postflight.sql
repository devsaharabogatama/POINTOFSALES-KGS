-- PRD-1 phase 2 postflight: UAT identity and two-Company tenant readiness.
-- SAFETY: one SELECT statement; aggregate counts only; no email/name/UUID output.

WITH required_roles(role_code) AS (
    VALUES
        ('COMPANY_OWNER'),('COMPANY_ADMIN'),('FINANCE'),('ACCOUNTING'),
        ('STORE_MANAGER'),('WAREHOUSE_ADMIN'),('CASHIER')
), active_companies AS (
    SELECT company.id
    FROM public.companies company
    WHERE company.status='ACTIVE'
), active_company_memberships AS (
    SELECT membership.company_id,membership.user_id,membership.role_code
    FROM public.company_memberships membership
    JOIN active_companies company ON company.id=membership.company_id
    JOIN auth.users auth_user ON auth_user.id=membership.user_id
    WHERE membership.status='ACTIVE'
), active_store_memberships AS (
    SELECT membership.company_id,membership.store_id,membership.user_id,
        membership.role_code
    FROM public.store_memberships membership
    JOIN active_companies company ON company.id=membership.company_id
    JOIN auth.users auth_user ON auth_user.id=membership.user_id
    WHERE membership.status='ACTIVE'
), checks AS (
    SELECT 'two_company_uat_scope'::TEXT check_name,
        CASE WHEN count(*)>=2 THEN 'PASS' ELSE 'SETUP' END status,
        jsonb_build_object(
            'active_companies',count(*),'required',2,
            'companies_to_provision',GREATEST(2-count(*),0)
        ) details
    FROM active_companies

    UNION ALL
    SELECT 'global_role_uat_matrix',
        CASE WHEN count(*) FILTER(WHERE membership.role_code IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.role_code ORDER BY required.role_code)
                    FILTER(WHERE membership.role_code IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_roles required
    LEFT JOIN (
        SELECT DISTINCT role_code FROM active_company_memberships
    ) membership ON membership.role_code=required.role_code

    UNION ALL
    SELECT 'company_management_identity_per_tenant',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('company_count',count(*))
    FROM active_companies company
    WHERE NOT EXISTS(
        SELECT 1 FROM active_company_memberships membership
        WHERE membership.company_id=company.id
          AND membership.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
    )

    UNION ALL
    SELECT 'cashier_identity_per_tenant',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('company_count',count(*))
    FROM active_companies company
    WHERE NOT EXISTS(
        SELECT 1 FROM active_store_memberships membership
        WHERE membership.company_id=company.id
          AND membership.role_code='CASHIER'
    )

    UNION ALL
    SELECT 'regular_multi_company_selector_identity',
        CASE WHEN count(*)>0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('eligible_users',count(*),'required',1)
    FROM (
        SELECT membership.user_id
        FROM active_company_memberships membership
        JOIN public.profiles profile ON profile.id=membership.user_id
        WHERE profile.role<>'super_admin'::public.user_role
        GROUP BY membership.user_id
        HAVING count(DISTINCT membership.company_id)>=2
    ) eligible

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
    SELECT 'store_membership_tenant_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.store_memberships membership
    LEFT JOIN public.stores store
      ON store.company_id=membership.company_id
     AND store.id=membership.store_id
    LEFT JOIN public.company_memberships company_membership
      ON company_membership.company_id=membership.company_id
     AND company_membership.user_id=membership.user_id
     AND company_membership.status='ACTIVE'
    WHERE membership.status='ACTIVE'
      AND (store.id IS NULL OR company_membership.id IS NULL)

    UNION ALL
    SELECT 'cashier_store_assignment_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM active_company_memberships membership
    WHERE membership.role_code='CASHIER'
      AND NOT EXISTS(
          SELECT 1 FROM active_store_memberships store_membership
          JOIN public.stores store
            ON store.company_id=store_membership.company_id
           AND store.id=store_membership.store_id
           AND store.status='ACTIVE'
          WHERE store_membership.company_id=membership.company_id
            AND store_membership.user_id=membership.user_id
            AND store_membership.role_code='CASHIER'
      )

    UNION ALL
    SELECT 'operational_scope_per_tenant',
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
    SELECT 'minimum_master_fixture_per_tenant',
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
    SELECT 'identity_tenant_inventory','INFO',jsonb_build_object(
        'active_companies',(SELECT count(*) FROM active_companies),
        'active_company_memberships',(SELECT count(*) FROM active_company_memberships),
        'active_store_memberships',(SELECT count(*) FROM active_store_memberships),
        'regular_multi_company_users',(
            SELECT count(*) FROM (
                SELECT membership.user_id
                FROM active_company_memberships membership
                JOIN public.profiles profile ON profile.id=membership.user_id
                WHERE profile.role<>'super_admin'::public.user_role
                GROUP BY membership.user_id
                HAVING count(DISTINCT membership.company_id)>=2
            ) users
        )
    )
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2 WHEN 'PASS' THEN 3 ELSE 4
END,check_name;

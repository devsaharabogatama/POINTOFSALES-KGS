-- ACP-2: shadow-only role baseline and per-Company restriction foundation.
-- No navigation, API, RPC, RLS, or business workflow consumes these overrides
-- as an enforcement decision in this phase.

BEGIN;

DO $migration_guard$
BEGIN
    IF (SELECT count(*) FROM private.kgs_schema_migrations
        WHERE version='20260811150000')<>1 THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: SLD-R4 missing';
    END IF;
    IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
              WHERE version='20260812120000') THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260812120000';
    END IF;
    IF to_regclass('public.access_permission_catalog') IS NOT NULL
       OR to_regclass('public.user_company_permission_overrides') IS NOT NULL
       OR to_regclass('public.user_company_permission_audit') IS NOT NULL THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP object collision';
    END IF;
END
$migration_guard$;

CREATE TABLE public.access_permission_catalog(
    permission_key TEXT PRIMARY KEY,
    module_key TEXT NOT NULL,
    permission_label TEXT NOT NULL,
    description TEXT NOT NULL,
    view_roles TEXT[] NOT NULL,
    operator_roles TEXT[] NOT NULL DEFAULT '{}',
    approver_roles TEXT[] NOT NULL DEFAULT '{}',
    supported_capabilities TEXT[] NOT NULL DEFAULT ARRAY['VIEW'],
    required_any_features TEXT[] NOT NULL DEFAULT '{}',
    is_customizable BOOLEAN NOT NULL DEFAULT TRUE,
    enforcement_status TEXT NOT NULL DEFAULT 'SHADOW',
    catalog_version BIGINT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT access_permission_key_check CHECK(
        permission_key~'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'
    ),
    CONSTRAINT access_permission_module_check CHECK(
        module_key IN('INVENTORY','CONTACTS','PURCHASE','SALES','FINANCE','DATA','PLATFORM')
    ),
    CONSTRAINT access_permission_enforcement_check CHECK(
        enforcement_status IN('SHADOW','ENFORCED','DISABLED')
    ),
    CONSTRAINT access_permission_roles_check CHECK(
        view_roles<@ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING','STORE_MANAGER','WAREHOUSE_ADMIN','CASHIER']::TEXT[]
        AND operator_roles<@view_roles AND approver_roles<@view_roles
    ),
    CONSTRAINT access_permission_capabilities_check CHECK(
        supported_capabilities<@ARRAY[
            'VIEW','CREATE_DRAFT','EDIT_DRAFT','MANAGE','REVIEW','APPROVE',
            'POST','CANCEL_FINAL','REVERSE','CLOSE_PERIOD','EXPORT','IMPORT'
        ]::TEXT[] AND 'VIEW'=ANY(supported_capabilities)
    ),
    CONSTRAINT access_permission_features_check CHECK(
        required_any_features<@ARRAY[
            'expense_enabled','customer_balance_enabled','tax_sales_enabled',
            'tax_purchase_enabled','offline_pos_enabled','negative_stock_enabled'
        ]::TEXT[]
    )
);

CREATE TABLE public.user_company_permission_overrides(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    permission_key TEXT NOT NULL REFERENCES public.access_permission_catalog(permission_key) ON DELETE RESTRICT,
    restriction_preset TEXT NOT NULL,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    updated_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_user_company_permission_override UNIQUE(company_id,user_id,permission_key),
    CONSTRAINT user_company_permission_preset_check CHECK(
        restriction_preset IN('LIHAT_SAJA','OPERASIONAL','TANPA_AKSES')
    ),
    CONSTRAINT user_company_permission_version_check CHECK(master_version>0)
);

CREATE INDEX idx_user_company_permission_overrides_user
    ON public.user_company_permission_overrides(user_id,company_id);

CREATE TABLE public.user_company_permission_audit(
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    target_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    permission_key TEXT NOT NULL REFERENCES public.access_permission_catalog(permission_key) ON DELETE RESTRICT,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    before_state JSONB,
    after_state JSONB,
    correlation_key UUID NOT NULL DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT user_company_permission_audit_action_check CHECK(
        action IN('CREATE_OVERRIDE','UPDATE_OVERRIDE','RESET_OVERRIDE')
    ),
    CONSTRAINT user_company_permission_audit_state_check CHECK(
        (before_state IS NULL OR jsonb_typeof(before_state)='object')
        AND (after_state IS NULL OR jsonb_typeof(after_state)='object')
        AND NOT(before_state IS NULL AND after_state IS NULL)
    )
);

CREATE INDEX idx_user_company_permission_audit_target
    ON public.user_company_permission_audit(company_id,target_user_id,created_at DESC);

INSERT INTO public.access_permission_catalog(
    permission_key,module_key,permission_label,description,view_roles,
    operator_roles,approver_roles,supported_capabilities,required_any_features,
    is_customizable
) VALUES
('inventory.master_data','INVENTORY','Master Inventory','Kategori, UOM, Gudang, Toko, dan Terminal',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],'{}',ARRAY['VIEW','MANAGE'],'{}',TRUE),
('inventory.products','INVENTORY','Produk & UOM','Produk dan satuan penjualan/pembelian',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],'{}',ARRAY['VIEW','MANAGE','EXPORT','IMPORT'],'{}',TRUE),
('inventory.stock_real','INVENTORY','Stock Real','Saldo stok aktual',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'],'{}','{}',ARRAY['VIEW','EXPORT'],'{}',TRUE),
('inventory.stock_movements','INVENTORY','Kartu Stok','Immutable stock movement',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'],'{}','{}',ARRAY['VIEW','EXPORT'],'{}',TRUE),
('inventory.stock_transfers','INVENTORY','Transfer Stok','Dokumen transfer antar Gudang',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL'],'{}',TRUE),
('inventory.stock_adjustments','INVENTORY','Penyesuaian Stok','Dokumen koreksi stok',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL'],'{}',TRUE),
('inventory.stock_opnames','INVENTORY','Stock Opname','Hitung, review, dan posting opname',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','POST','CANCEL_FINAL'],'{}',TRUE),
('inventory.opening_stock','INVENTORY','Stok Awal','Dokumen saldo awal',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','POST'],'{}',TRUE),
('inventory.minimum_stock','INVENTORY','Minimum Stock','Konfigurasi minimum stok',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],'{}',ARRAY['VIEW','MANAGE','EXPORT','IMPORT'],'{}',TRUE),
('contacts.customers','CONTACTS','Pelanggan','Customer, cabang, kategori, dan Pricelist',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],'{}',ARRAY['VIEW','MANAGE','EXPORT'],'{}',TRUE),
('contacts.suppliers','CONTACTS','Supplier','Supplier dan relasi pembelian',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],'{}',ARRAY['VIEW','MANAGE','EXPORT','IMPORT'],'{}',TRUE),
('contacts.staff_access','CONTACTS','User & Akses','Membership, role, Store, dan permission',ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],'{}',ARRAY['VIEW','MANAGE'],'{}',TRUE),
('purchase.supplier_orders','PURCHASE','Supplier Order','Permintaan dan pesanan Supplier',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL'],'{}',TRUE),
('purchase.purchase_returns','PURCHASE','Retur Pembelian','Review dan posting retur Supplier',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','POST','CANCEL_FINAL'],'{}',TRUE),
('sales.sales_documents','SALES','Invoice & Surat Jalan','Dokumen final dan delivery lifecycle',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],'{}',ARRAY['VIEW','MANAGE','EXPORT'],'{}',TRUE),
('sales.pricelists','SALES','Pricelist','Harga jual dan assignment Customer',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],'{}',ARRAY['VIEW','MANAGE','EXPORT'],'{}',TRUE),
('sales.bundles','SALES','Bundle','Bundle dan komponen',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],'{}',ARRAY['VIEW','MANAGE'],'{}',TRUE),
('sales.sales_returns','SALES','Approval Return','Review dan posting retur penjualan',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['VIEW','REVIEW','POST','CANCEL_FINAL'],'{}',TRUE),
('finance.expenses','FINANCE','Expense','Request, approval, disbursement, settlement',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','FINANCE'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','APPROVE','POST','CANCEL_FINAL'],ARRAY['expense_enabled'],TRUE),
('finance.cash_deposits','FINANCE','Setor Kas','Setoran dan review kas',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['VIEW','REVIEW','APPROVE','POST'],'{}',TRUE),
('finance.deposit_variances','FINANCE','Selisih Setoran','Investigasi dan resolusi variance',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['VIEW','MANAGE','REVIEW','APPROVE','POST'],'{}',TRUE),
('finance.customer_balances','FINANCE','Saldo Customer','Ledger dan koreksi terkontrol',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['VIEW','MANAGE','REVIEW','APPROVE','EXPORT'],ARRAY['customer_balance_enabled'],TRUE),
('finance.supplier_invoices','FINANCE','Faktur Supplier','Matching dan validasi invoice',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','APPROVE','POST','EXPORT'],'{}',TRUE),
('finance.supplier_payments','FINANCE','Pembayaran Supplier','Validasi pembayaran AP',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','REVIEW','APPROVE','POST','EXPORT'],'{}',TRUE),
('finance.payment_methods','FINANCE','Metode Pembayaran','Metode, Store, fee, dan route',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],'{}',ARRAY['VIEW','MANAGE','EXPORT'],'{}',TRUE),
('finance.tax_rules','FINANCE','Aturan Pajak','Tax Rule dan assignment',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],'{}',ARRAY['VIEW','MANAGE','EXPORT'],ARRAY['tax_sales_enabled','tax_purchase_enabled'],TRUE),
('finance.master_data','FINANCE','Kategori & COA','Kategori transaksi, COA, dan mapping',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],'{}',ARRAY['VIEW','MANAGE','EXPORT','IMPORT'],'{}',TRUE),
('finance.journals_reports','FINANCE','Jurnal Keuangan','Journal, ledger, periode, dan report',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'],'{}',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],ARRAY['VIEW','REVIEW','APPROVE','POST','REVERSE','CLOSE_PERIOD','EXPORT'],'{}',TRUE),
('data.exchange','DATA','Data Exchange','Global export/import center',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],'{}',ARRAY['VIEW','EXPORT','IMPORT'],'{}',TRUE),
('platform.company_branding','PLATFORM','Logo Perusahaan','Branding Company aktif',ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],'{}',ARRAY['VIEW','MANAGE'],'{}',TRUE),
('platform.module_settings','PLATFORM','Pengaturan Modul','Operational policy; entitlement tetap Super Admin',ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],ARRAY['COMPANY_OWNER','COMPANY_ADMIN'],'{}',ARRAY['VIEW','MANAGE'],'{}',TRUE),
('platform.companies','PLATFORM','Perusahaan','Platform tenant management','{}','{}','{}',ARRAY['VIEW','MANAGE'],'{}',FALSE);

ALTER TABLE public.access_permission_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_company_permission_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_company_permission_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY access_permission_catalog_authenticated_read
ON public.access_permission_catalog FOR SELECT TO authenticated
USING(auth.uid() IS NOT NULL);

CREATE FUNCTION private.trg_acp_guard_permission_history()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$ BEGIN RAISE EXCEPTION 'USER_COMPANY_PERMISSION_AUDIT_IMMUTABLE'; END; $$;

CREATE TRIGGER trg_acp_guard_permission_history
BEFORE UPDATE OR DELETE ON public.user_company_permission_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_acp_guard_permission_history();

CREATE FUNCTION private.acp_can_manage_target(
    p_actor UUID,p_company_id UUID,p_target_user_id UUID
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
    SELECT CASE
      WHEN p_actor IS NULL OR p_actor=p_target_user_id THEN FALSE
      WHEN public.private_is_super_admin(p_actor) THEN EXISTS(
          SELECT 1 FROM public.company_memberships target
          WHERE target.company_id=p_company_id AND target.user_id=p_target_user_id
            AND target.status='ACTIVE'
      )
      ELSE EXISTS(
          SELECT 1
          FROM public.company_memberships actor
          JOIN public.company_memberships target
            ON target.company_id=actor.company_id
           AND target.user_id=p_target_user_id AND target.status='ACTIVE'
          WHERE actor.company_id=p_company_id AND actor.user_id=p_actor
            AND actor.status='ACTIVE'
            AND (
              (actor.role_code='COMPANY_OWNER' AND target.role_code<>'COMPANY_OWNER')
              OR (actor.role_code='COMPANY_ADMIN' AND target.role_code NOT IN('COMPANY_OWNER','COMPANY_ADMIN'))
            )
      ) END;
$$;

CREATE FUNCTION private.acp_resolve_permission(
    p_company_id UUID,p_target_user_id UUID,p_permission_key TEXT
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
    v_catalog public.access_permission_catalog%ROWTYPE;
    v_override public.user_company_permission_overrides%ROWTYPE;
    v_role TEXT;
    v_baseline TEXT[]:='{}';
    v_effective TEXT[]:='{}';
    v_feature_enabled BOOLEAN:=TRUE;
BEGIN
    SELECT * INTO v_catalog FROM public.access_permission_catalog
    WHERE permission_key=p_permission_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'PERMISSION_KEY_NOT_FOUND'; END IF;

    IF public.private_is_super_admin(p_target_user_id) THEN v_role:='SUPER_ADMIN';
    ELSE
      SELECT role_code INTO v_role FROM public.company_memberships
      WHERE company_id=p_company_id AND user_id=p_target_user_id AND status='ACTIVE';
    END IF;
    IF v_role IS NULL THEN RAISE EXCEPTION 'TARGET_COMPANY_MEMBERSHIP_NOT_FOUND'; END IF;

    IF cardinality(v_catalog.required_any_features)>0 THEN
      SELECT EXISTS(SELECT 1 FROM public.company_features feature
        WHERE feature.company_id=p_company_id AND feature.is_enabled
          AND feature.feature_code=ANY(v_catalog.required_any_features))
      INTO v_feature_enabled;
    END IF;

    IF v_feature_enabled AND (v_role='SUPER_ADMIN' OR v_role=ANY(v_catalog.view_roles)) THEN
      v_baseline:=ARRAY['VIEW'];
      IF v_role='SUPER_ADMIN' OR v_role=ANY(v_catalog.operator_roles) THEN
        v_baseline:=v_baseline||ARRAY['CREATE_DRAFT','EDIT_DRAFT','MANAGE'];
      END IF;
      IF v_role='SUPER_ADMIN' OR v_role=ANY(v_catalog.approver_roles) THEN
        v_baseline:=v_baseline||ARRAY['REVIEW','APPROVE','POST','CANCEL_FINAL','REVERSE','CLOSE_PERIOD'];
      END IF;
      IF v_role='SUPER_ADMIN' OR v_role=ANY(v_catalog.view_roles) THEN
        v_baseline:=v_baseline||ARRAY['EXPORT'];
      END IF;
      IF v_role='SUPER_ADMIN' OR v_role IN('COMPANY_OWNER','COMPANY_ADMIN') THEN
        v_baseline:=v_baseline||ARRAY['IMPORT'];
      END IF;
      SELECT COALESCE(array_agg(DISTINCT capability ORDER BY capability),'{}')
      INTO v_baseline FROM unnest(v_baseline) capability
      WHERE capability=ANY(v_catalog.supported_capabilities);
    END IF;

    SELECT * INTO v_override FROM public.user_company_permission_overrides
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND permission_key=p_permission_key;

    IF v_override.id IS NULL THEN v_effective:=v_baseline;
    ELSIF v_override.restriction_preset='LIHAT_SAJA' THEN
      SELECT COALESCE(array_agg(capability ORDER BY capability),'{}') INTO v_effective
      FROM unnest(v_baseline) capability WHERE capability='VIEW';
    ELSIF v_override.restriction_preset='OPERASIONAL' THEN
      SELECT COALESCE(array_agg(capability ORDER BY capability),'{}') INTO v_effective
      FROM unnest(v_baseline) capability
      WHERE capability IN('VIEW','CREATE_DRAFT','EDIT_DRAFT');
    ELSE v_effective:='{}'; END IF;

    RETURN jsonb_build_object(
      'companyId',p_company_id,'userId',p_target_user_id,
      'permissionKey',p_permission_key,'roleCode',v_role,
      'featureEnabled',v_feature_enabled,
      'baselineCapabilities',to_jsonb(v_baseline),
      'restrictionPreset',COALESCE(v_override.restriction_preset,'IKUTI_ROLE'),
      'overrideVersion',v_override.master_version,
      'effectiveCapabilities',to_jsonb(v_effective),
      'enforcementStatus',v_catalog.enforcement_status,
      'enforced',v_catalog.enforcement_status='ENFORCED'
    );
END;
$$;

CREATE FUNCTION public.resolve_user_permission(
    p_company_id UUID,p_target_user_id UUID,p_permission_key TEXT
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_actor UUID:=auth.uid();
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_actor<>p_target_user_id
       AND NOT private.acp_can_manage_target(v_actor,p_company_id,p_target_user_id) THEN
      RAISE EXCEPTION 'PERMISSION_TARGET_ACCESS_DENIED';
    END IF;
    RETURN private.acp_resolve_permission(p_company_id,p_target_user_id,p_permission_key);
END;
$$;

CREATE FUNCTION public.list_user_permission_profile(
    p_company_id UUID,p_target_user_id UUID
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_actor UUID:=auth.uid();v_items JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_actor<>p_target_user_id
       AND NOT private.acp_can_manage_target(v_actor,p_company_id,p_target_user_id) THEN
      RAISE EXCEPTION 'PERMISSION_TARGET_ACCESS_DENIED';
    END IF;
    SELECT COALESCE(jsonb_agg(
      private.acp_resolve_permission(p_company_id,p_target_user_id,catalog.permission_key)
      ORDER BY catalog.module_key,catalog.permission_key
    ),'[]'::JSONB) INTO v_items
    FROM public.access_permission_catalog catalog;
    RETURN jsonb_build_object('companyId',p_company_id,'userId',p_target_user_id,'items',v_items);
END;
$$;

CREATE FUNCTION public.save_user_permission_override(
    p_company_id UUID,p_target_user_id UUID,p_permission_key TEXT,
    p_restriction_preset TEXT,p_expected_version BIGINT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();v_preset TEXT:=upper(btrim(COALESCE(p_restriction_preset,'')));
    v_catalog public.access_permission_catalog%ROWTYPE;
    v_current public.user_company_permission_overrides%ROWTYPE;
    v_result public.user_company_permission_overrides%ROWTYPE;
    v_before JSONB;v_after JSONB;v_action TEXT;v_new_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT private.acp_can_manage_target(v_actor,p_company_id,p_target_user_id) THEN
      RAISE EXCEPTION 'PERMISSION_TARGET_ACCESS_DENIED';
    END IF;
    IF v_preset NOT IN('IKUTI_ROLE','LIHAT_SAJA','OPERASIONAL','TANPA_AKSES') THEN
      RAISE EXCEPTION 'PERMISSION_PRESET_INVALID';
    END IF;
    SELECT * INTO v_catalog FROM public.access_permission_catalog
    WHERE permission_key=p_permission_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'PERMISSION_KEY_NOT_FOUND'; END IF;
    IF NOT v_catalog.is_customizable THEN RAISE EXCEPTION 'PERMISSION_KEY_NOT_CUSTOMIZABLE'; END IF;
    IF v_preset<>'IKUTI_ROLE' AND EXISTS(
      SELECT 1 FROM public.company_memberships target
      WHERE target.company_id=p_company_id AND target.user_id=p_target_user_id
        AND target.status='ACTIVE' AND target.role_code='COMPANY_OWNER'
    ) AND (
      SELECT count(*) FROM public.company_memberships owner_membership
      WHERE owner_membership.company_id=p_company_id
        AND owner_membership.status='ACTIVE'
        AND owner_membership.role_code='COMPANY_OWNER'
    )<=1 THEN
      RAISE EXCEPTION 'LAST_COMPANY_OWNER_ACCESS_PROTECTED';
    END IF;

    SELECT * INTO v_current FROM public.user_company_permission_overrides
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND permission_key=p_permission_key FOR UPDATE;
    IF v_current.id IS NOT NULL AND v_current.restriction_preset=v_preset THEN
      RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY',
        'permissionKey',p_permission_key,'restrictionPreset',v_preset,
        'masterVersion',v_current.master_version,'enforced',FALSE);
    END IF;
    IF v_current.id IS NULL AND v_preset='IKUTI_ROLE' THEN
      RETURN jsonb_build_object('success',TRUE,'action','EXACT_RETRY',
        'permissionKey',p_permission_key,'restrictionPreset',v_preset,
        'masterVersion',NULL,'enforced',FALSE);
    END IF;
    IF v_current.id IS NOT NULL AND p_expected_version IS DISTINCT FROM v_current.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_current.id IS NULL AND p_expected_version IS NOT NULL THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=CASE WHEN v_current.id IS NULL THEN NULL ELSE jsonb_build_object(
      'restrictionPreset',v_current.restriction_preset,'masterVersion',v_current.master_version) END;

    IF v_preset='IKUTI_ROLE' THEN
      DELETE FROM public.user_company_permission_overrides WHERE id=v_current.id;
      v_action:='RESET_OVERRIDE';v_after:=jsonb_build_object('restrictionPreset','IKUTI_ROLE');
      v_new_version:=NULL;
    ELSIF v_current.id IS NULL THEN
      INSERT INTO public.user_company_permission_overrides(
        company_id,user_id,permission_key,restriction_preset,created_by,updated_by
      ) VALUES(p_company_id,p_target_user_id,p_permission_key,v_preset,v_actor,v_actor)
      RETURNING * INTO v_result;
      v_action:='CREATE_OVERRIDE';
      v_new_version:=v_result.master_version;
      v_after:=jsonb_build_object('restrictionPreset',v_result.restriction_preset,'masterVersion',v_result.master_version);
    ELSE
      UPDATE public.user_company_permission_overrides SET
        restriction_preset=v_preset,master_version=master_version+1,
        updated_by=v_actor,updated_at=clock_timestamp()
      WHERE id=v_current.id RETURNING * INTO v_result;
      v_action:='UPDATE_OVERRIDE';
      v_new_version:=v_result.master_version;
      v_after:=jsonb_build_object('restrictionPreset',v_result.restriction_preset,'masterVersion',v_result.master_version);
    END IF;

    INSERT INTO public.user_company_permission_audit(
      company_id,target_user_id,permission_key,actor_id,action,before_state,after_state
    ) VALUES(p_company_id,p_target_user_id,p_permission_key,v_actor,v_action,v_before,v_after);
    RETURN jsonb_build_object('success',TRUE,'action',v_action,
      'permissionKey',p_permission_key,'restrictionPreset',v_preset,
      'masterVersion',v_new_version,'enforced',FALSE);
END;
$$;

REVOKE ALL ON public.access_permission_catalog,
    public.user_company_permission_overrides,
    public.user_company_permission_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.access_permission_catalog TO authenticated;

REVOKE ALL ON FUNCTION public.resolve_user_permission(UUID,UUID,TEXT),
    public.list_user_permission_profile(UUID,UUID),
    public.save_user_permission_override(UUID,UUID,TEXT,TEXT,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.resolve_user_permission(UUID,UUID,TEXT),
    public.list_user_permission_profile(UUID,UUID),
    public.save_user_permission_override(UUID,UUID,TEXT,TEXT,BIGINT)
TO authenticated,service_role;

REVOKE ALL ON FUNCTION private.acp_can_manage_target(UUID,UUID,UUID),
    private.acp_resolve_permission(UUID,UUID,TEXT),
    private.trg_acp_guard_permission_history()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.acp_can_manage_target(UUID,UUID,UUID),
    private.acp_resolve_permission(UUID,UUID,TEXT),
    private.trg_acp_guard_permission_history() TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260812120000','acp_phase2_shadow_permission_foundation',
 'Restriction-only per-Company permission catalog, versioned override, immutable audit, guarded preview/save RPC, and SHADOW-only no-runtime-enforcement contract');

COMMIT;

-- Purchase Daily Replenishment Step 1/6.
-- Adds Company mode, deterministic Product-Supplier priority and an inert daily
-- grouping ledger. This migration does not generate RO/PO or mutate Stock/AP.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: isolated development chain 20260912140000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260913100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260913100000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
      WHERE status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open Sales process cutover plan';
  END IF;
  IF to_regclass('public.company_purchase_replenishment_settings') IS NOT NULL
    OR to_regclass('public.company_purchase_replenishment_setting_audit') IS NOT NULL
    OR to_regclass('public.purchase_daily_batches') IS NOT NULL
    OR to_regclass('public.purchase_daily_batch_lines') IS NOT NULL
    OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='product_suppliers' AND column_name='selection_priority') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase replenishment foundation collision';
  END IF;
END
$guard$;

ALTER TABLE public.product_suppliers ADD COLUMN selection_priority integer;

WITH ranked AS (
  SELECT relation.id,row_number() OVER(PARTITION BY relation.company_id,relation.product_id
    ORDER BY relation.is_preferred_supplier DESC,relation.created_at,relation.id)::integer priority
  FROM public.product_suppliers relation
)
UPDATE public.product_suppliers relation SET selection_priority=ranked.priority
FROM ranked WHERE ranked.id=relation.id;

ALTER TABLE public.product_suppliers
  ALTER COLUMN selection_priority SET NOT NULL,
  ALTER COLUMN selection_priority SET DEFAULT 100,
  ADD CONSTRAINT product_suppliers_selection_priority_positive CHECK(selection_priority>0);

COMMENT ON COLUMN public.product_suppliers.selection_priority IS
  'Deterministic purchase selection order per Product. Lowest active priority wins when user does not choose a Supplier.';

CREATE TABLE public.company_purchase_replenishment_settings(
  company_id uuid PRIMARY KEY REFERENCES public.companies(id) ON DELETE RESTRICT,
  replenishment_mode text NOT NULL DEFAULT 'MANUAL',
  cutoff_local_time time NOT NULL DEFAULT time '23:59:00',
  target_on_hand_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT company_purchase_replenishment_mode_check CHECK(
    replenishment_mode IN('MANUAL','AUTO_RO','AUTO_PO')),
  CONSTRAINT company_purchase_replenishment_cutoff_fixed CHECK(cutoff_local_time=time '23:59:00'),
  CONSTRAINT company_purchase_replenishment_target_zero CHECK(target_on_hand_base_qty=0),
  CONSTRAINT company_purchase_replenishment_version_positive CHECK(master_version>0)
);

CREATE TABLE public.company_purchase_replenishment_setting_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  action text NOT NULL CHECK(action IN('PROVISION','MODE_CHANGE')),
  actor_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state jsonb,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE SEQUENCE private.purchase_daily_batch_no_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE private.purchase_daily_batch_no_seq FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.purchase_daily_batch_no_seq TO service_role;

CREATE TABLE public.purchase_daily_batches(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  batch_no text NOT NULL,
  business_date date NOT NULL,
  mode_snapshot text NOT NULL,
  status text NOT NULL DEFAULT 'DRAFT',
  cutoff_at timestamptz NOT NULL,
  line_count integer NOT NULL DEFAULT 0,
  requested_total_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  generated_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  master_version bigint NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_daily_batches_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT purchase_daily_batches_company_no_unique UNIQUE(company_id,batch_no),
  CONSTRAINT purchase_daily_batches_company_date_unique UNIQUE(company_id,business_date),
  CONSTRAINT purchase_daily_batches_mode_check CHECK(mode_snapshot IN('AUTO_RO','AUTO_PO')),
  CONSTRAINT purchase_daily_batches_status_check CHECK(status IN(
    'DRAFT','READY','PARTIALLY_RECEIVED','RECEIVED','CANCELED')),
  CONSTRAINT purchase_daily_batches_totals_check CHECK(
    line_count>=0 AND requested_total_base_qty>=0),
  CONSTRAINT purchase_daily_batches_version_check CHECK(master_version>0)
);

CREATE TABLE public.purchase_daily_batch_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  batch_id uuid NOT NULL,
  line_no integer NOT NULL,
  product_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  base_uom_id uuid NOT NULL,
  on_hand_snapshot numeric(24,6) NOT NULL,
  open_purchase_base_qty_snapshot numeric(24,6) NOT NULL DEFAULT 0,
  requested_base_qty numeric(24,6) NOT NULL,
  suggested_product_supplier_id uuid,
  suggested_supplier_id uuid,
  supplier_assignment_status text NOT NULL,
  product_sku_snapshot text NOT NULL,
  product_name_snapshot text NOT NULL,
  warehouse_code_snapshot text NOT NULL,
  warehouse_name_snapshot text NOT NULL,
  base_uom_name_snapshot text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_daily_batch_lines_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT purchase_daily_batch_lines_line_unique UNIQUE(company_id,batch_id,line_no),
  CONSTRAINT purchase_daily_batch_lines_product_warehouse_unique
    UNIQUE(company_id,batch_id,product_id,warehouse_id),
  CONSTRAINT purchase_daily_batch_lines_batch_fk FOREIGN KEY(company_id,batch_id)
    REFERENCES public.purchase_daily_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_batch_lines_product_fk FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_batch_lines_warehouse_fk FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_batch_lines_uom_fk FOREIGN KEY(company_id,base_uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_batch_lines_product_supplier_fk
    FOREIGN KEY(company_id,suggested_product_supplier_id)
    REFERENCES public.product_suppliers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_batch_lines_supplier_fk FOREIGN KEY(company_id,suggested_supplier_id)
    REFERENCES public.suppliers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_daily_batch_lines_number_check CHECK(line_no>0),
  CONSTRAINT purchase_daily_batch_lines_quantity_check CHECK(
    on_hand_snapshot<0 AND open_purchase_base_qty_snapshot>=0 AND requested_base_qty>0),
  CONSTRAINT purchase_daily_batch_lines_supplier_status_check CHECK(
    (supplier_assignment_status='ASSIGNED' AND suggested_product_supplier_id IS NOT NULL
      AND suggested_supplier_id IS NOT NULL)
    OR (supplier_assignment_status='SUPPLIER_PENDING' AND suggested_product_supplier_id IS NULL
      AND suggested_supplier_id IS NULL)),
  CONSTRAINT purchase_daily_batch_lines_snapshot_check CHECK(
    btrim(product_sku_snapshot)<>'' AND btrim(product_name_snapshot)<>''
    AND btrim(warehouse_code_snapshot)<>'' AND btrim(warehouse_name_snapshot)<>''
    AND btrim(base_uom_name_snapshot)<>'')
);

CREATE INDEX purchase_daily_batches_company_status_idx
  ON public.purchase_daily_batches(company_id,status,business_date DESC);
CREATE INDEX purchase_daily_batch_lines_supplier_idx
  ON public.purchase_daily_batch_lines(company_id,batch_id,suggested_supplier_id,warehouse_id);

CREATE FUNCTION private.trg_guard_purchase_replenishment_history()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_HISTORY_IMMUTABLE';
END
$$;

CREATE TRIGGER guard_purchase_replenishment_setting_audit
BEFORE UPDATE OR DELETE ON public.company_purchase_replenishment_setting_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_purchase_replenishment_history();

CREATE FUNCTION private.trg_provision_purchase_replenishment_setting()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_setting public.company_purchase_replenishment_settings%rowtype;
BEGIN
  INSERT INTO public.company_purchase_replenishment_settings(company_id)
  VALUES(NEW.id) RETURNING * INTO v_setting;
  INSERT INTO public.company_purchase_replenishment_setting_audit(
    company_id,action,after_state) VALUES(NEW.id,'PROVISION',to_jsonb(v_setting));
  RETURN NEW;
END
$$;

CREATE TRIGGER provision_purchase_replenishment_setting
AFTER INSERT ON public.companies FOR EACH ROW
EXECUTE FUNCTION private.trg_provision_purchase_replenishment_setting();

INSERT INTO public.company_purchase_replenishment_settings(company_id)
SELECT company.id FROM public.companies company
ON CONFLICT(company_id) DO NOTHING;

INSERT INTO public.company_purchase_replenishment_setting_audit(company_id,action,after_state)
SELECT setting.company_id,'PROVISION',to_jsonb(setting)
FROM public.company_purchase_replenishment_settings setting
WHERE NOT EXISTS(SELECT 1 FROM public.company_purchase_replenishment_setting_audit audit
  WHERE audit.company_id=setting.company_id AND audit.action='PROVISION');

CREATE FUNCTION public.get_purchase_replenishment_setting()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_setting record;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'purchase.supplier_orders','VIEW');
  SELECT setting.*,company.timezone INTO v_setting
  FROM public.company_purchase_replenishment_settings setting
  JOIN public.companies company ON company.id=setting.company_id
  WHERE setting.company_id=v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('companyId',v_company,'mode',v_setting.replenishment_mode,
    'cutoffLocalTime',to_char(v_setting.cutoff_local_time,'HH24:MI'),
    'targetOnHandBaseQty',v_setting.target_on_hand_base_qty,
    'timezone',v_setting.timezone,'masterVersion',v_setting.master_version,
    'updatedAt',v_setting.updated_at);
END
$$;

CREATE FUNCTION public.set_purchase_replenishment_mode(p_mode text,p_master_version bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_before public.company_purchase_replenishment_settings%rowtype;
  v_after public.company_purchase_replenishment_settings%rowtype;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile
      WHERE profile.id=v_actor AND profile.role='super_admin') THEN
    RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN('MANUAL','AUTO_RO','AUTO_PO') THEN
    RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_MODE_INVALID';
  END IF;
  SELECT * INTO v_before FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND'; END IF;
  IF p_master_version IS NULL OR p_master_version<>v_before.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_before.replenishment_mode=p_mode THEN
    RETURN jsonb_build_object('companyId',v_company,'mode',p_mode,
      'masterVersion',v_before.master_version,'changed',false);
  END IF;
  UPDATE public.company_purchase_replenishment_settings SET
    replenishment_mode=p_mode,master_version=master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company RETURNING * INTO v_after;
  INSERT INTO public.company_purchase_replenishment_setting_audit(
    company_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'MODE_CHANGE',v_actor,to_jsonb(v_before),to_jsonb(v_after));
  RETURN jsonb_build_object('companyId',v_company,'mode',v_after.replenishment_mode,
    'masterVersion',v_after.master_version,'changed',true);
END
$$;

ALTER TABLE public.company_purchase_replenishment_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_purchase_replenishment_setting_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_daily_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_daily_batch_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY purchase_replenishment_settings_read ON public.company_purchase_replenishment_settings
FOR SELECT TO authenticated USING(company_id=public.private_active_company_id());
CREATE POLICY purchase_replenishment_setting_audit_read ON public.company_purchase_replenishment_setting_audit
FOR SELECT TO authenticated USING(company_id=public.private_active_company_id());
CREATE POLICY purchase_daily_batches_read ON public.purchase_daily_batches
FOR SELECT TO authenticated USING(company_id=public.private_active_company_id());
CREATE POLICY purchase_daily_batch_lines_read ON public.purchase_daily_batch_lines
FOR SELECT TO authenticated USING(company_id=public.private_active_company_id());

REVOKE ALL ON public.company_purchase_replenishment_settings,
  public.company_purchase_replenishment_setting_audit,public.purchase_daily_batches,
  public.purchase_daily_batch_lines FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.company_purchase_replenishment_settings,
  public.company_purchase_replenishment_setting_audit,public.purchase_daily_batches,
  public.purchase_daily_batch_lines TO authenticated;
GRANT ALL ON public.company_purchase_replenishment_settings,
  public.company_purchase_replenishment_setting_audit,public.purchase_daily_batches,
  public.purchase_daily_batch_lines TO service_role;

REVOKE ALL ON FUNCTION public.get_purchase_replenishment_setting(),
  public.set_purchase_replenishment_mode(text,bigint)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_replenishment_setting(),
  public.set_purchase_replenishment_mode(text,bigint)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.trg_guard_purchase_replenishment_history(),
  private.trg_provision_purchase_replenishment_setting()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_purchase_replenishment_history(),
  private.trg_provision_purchase_replenishment_setting()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260913100000','purchase_daily_replenishment_foundation',
  'Purchase Step 1/6: Company MANUAL/AUTO_RO/AUTO_PO setting default MANUAL, deterministic Product-Supplier priority, inert daily cross-Warehouse grouping ledger, immutable setting audit and zero Stock/FIFO/AP/Finance effect');

COMMIT;

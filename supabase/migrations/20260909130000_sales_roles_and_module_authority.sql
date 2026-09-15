-- Additive Backoffice Sales roles. Isolated Development rollout only.
-- No Stock, Reservation, Delivery, Invoice, Payment, or Finance mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909120000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Pricelist header required';
  END IF;
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909130000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909130000';
  END IF;
  IF to_regprocedure('public.save_user_company_access(uuid,uuid,text,uuid)') IS NULL
    OR to_regclass('public.access_permission_catalog') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical access runtime missing';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
END
$guard$;

ALTER TABLE public.company_memberships
  DROP CONSTRAINT company_memberships_role_code_check;
ALTER TABLE public.company_memberships
  ADD CONSTRAINT company_memberships_role_code_check CHECK(role_code IN(
    'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING','STORE_MANAGER',
    'WAREHOUSE_ADMIN','SALES','SALES_ADMIN','CASHIER'
  )) NOT VALID;
ALTER TABLE public.company_memberships
  VALIDATE CONSTRAINT company_memberships_role_code_check;

ALTER TABLE public.store_memberships
  DROP CONSTRAINT store_memberships_role_code_check;
ALTER TABLE public.store_memberships
  ADD CONSTRAINT store_memberships_role_code_check CHECK(role_code IN(
    'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING','STORE_MANAGER',
    'WAREHOUSE_ADMIN','SALES','SALES_ADMIN','CASHIER'
  )) NOT VALID;
ALTER TABLE public.store_memberships
  VALIDATE CONSTRAINT store_memberships_role_code_check;

ALTER TABLE public.access_permission_catalog
  DROP CONSTRAINT access_permission_roles_check;
ALTER TABLE public.access_permission_catalog
  ADD CONSTRAINT access_permission_roles_check CHECK(
    view_roles <@ ARRAY[
      'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING','STORE_MANAGER',
      'WAREHOUSE_ADMIN','SALES','SALES_ADMIN','CASHIER'
    ]::text[]
    AND operator_roles <@ view_roles
    AND approver_roles <@ view_roles
  );

-- Both roles intentionally receive all capabilities supported by every Sales
-- permission. They remain Company-scoped through the existing membership and
-- active-company resolver. Super Admin behavior is unchanged.
UPDATE public.access_permission_catalog catalog
SET view_roles=(
      SELECT ARRAY(SELECT DISTINCT role_name FROM unnest(
        catalog.view_roles||ARRAY['SALES','SALES_ADMIN']::text[]
      ) role_name ORDER BY role_name)
    ),
    operator_roles=(
      SELECT ARRAY(SELECT DISTINCT role_name FROM unnest(
        catalog.operator_roles||ARRAY['SALES','SALES_ADMIN']::text[]
      ) role_name ORDER BY role_name)
    ),
    approver_roles=(
      SELECT ARRAY(SELECT DISTINCT role_name FROM unnest(
        catalog.approver_roles||ARRAY['SALES','SALES_ADMIN']::text[]
      ) role_name ORDER BY role_name)
    ),
    catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
WHERE module_key='SALES';

-- The latest lifecycle function contains the canonical hierarchy, Store, audit,
-- default-company, and exact-retry behavior. Change only its accepted vocabulary
-- and abort if the expected body has drifted.
DO $extend_assignment_role_vocabulary$
DECLARE
  v_definition text;
  v_extended text;
  v_old text := '''STORE_MANAGER'',''WAREHOUSE_ADMIN'',''CASHIER''';
  v_new text := '''STORE_MANAGER'',''WAREHOUSE_ADMIN'',''SALES'',''SALES_ADMIN'',''CASHIER''';
BEGIN
  SELECT pg_get_functiondef(
    'public.save_user_company_access(uuid,uuid,text,uuid)'::regprocedure
  ) INTO v_definition;
  IF (length(v_definition)-length(replace(v_definition,v_old,'')))
       / nullif(length(v_old),0) <> 1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: role validator definition drift';
  END IF;
  v_extended:=replace(v_definition,v_old,v_new);
  EXECUTE v_extended;
END
$extend_assignment_role_vocabulary$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20260909130000','sales_roles_and_module_authority',
  'Add Company-scoped SALES and SALES_ADMIN membership roles and grant both the supported capabilities of Sales permissions; Super Admin and all tenant guards remain unchanged'
);

NOTIFY pgrst,'reload schema';
COMMIT;

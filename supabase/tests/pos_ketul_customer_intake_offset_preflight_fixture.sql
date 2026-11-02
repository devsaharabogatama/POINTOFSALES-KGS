\set ON_ERROR_STOP on

BEGIN;

CREATE SCHEMA private;

CREATE TABLE public.companies (
  id uuid PRIMARY KEY,
  company_code text UNIQUE NOT NULL,
  company_name text NOT NULL
);

CREATE TABLE private.kgs_schema_migrations (version text PRIMARY KEY);

CREATE TABLE public.company_features (
  company_id uuid NOT NULL,
  feature_code text NOT NULL,
  is_enabled boolean NOT NULL,
  config jsonb NOT NULL
);

CREATE TABLE public.product_categories (
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL,
  category_code text NOT NULL,
  category_name text NOT NULL,
  is_active boolean NOT NULL
);

CREATE TABLE public.uoms (
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL,
  is_active boolean NOT NULL
);

CREATE TABLE public.products (
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL,
  category_id uuid,
  uom_id uuid,
  sku text NOT NULL,
  name text NOT NULL,
  is_active boolean NOT NULL
);

CREATE TABLE public.payment_methods (
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL,
  payment_method_code text NOT NULL,
  payment_method_name text NOT NULL,
  method_type text NOT NULL,
  settlement_route text NOT NULL,
  is_active boolean NOT NULL,
  is_system_method boolean NOT NULL
);

CREATE TABLE public.system_events (
  system_key text PRIMARY KEY,
  required_account_functions text[] NOT NULL,
  conditional_account_functions text[] NOT NULL,
  is_active boolean NOT NULL
);

CREATE TABLE public.transaction_categories (
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL,
  category_code text NOT NULL,
  system_key text NOT NULL,
  is_active boolean NOT NULL
);

CREATE TABLE public.chart_of_accounts (
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL,
  account_code text NOT NULL,
  account_name text NOT NULL,
  account_type text NOT NULL,
  normal_balance text NOT NULL,
  parent_account_id uuid,
  system_function_key text,
  is_active boolean NOT NULL,
  is_postable boolean NOT NULL,
  is_system_account boolean NOT NULL
);

CREATE TABLE public.transaction_account_rules (
  company_id uuid NOT NULL,
  transaction_category_id uuid NOT NULL,
  account_function_key text NOT NULL,
  account_id uuid NOT NULL,
  status text NOT NULL,
  effective_from timestamptz NOT NULL,
  effective_to timestamptz
);

CREATE TABLE public.finance_posting_queue_runs (status text NOT NULL);
CREATE TABLE public.pos_offline_sale_submissions (status text NOT NULL);

CREATE FUNCTION private.post_pos_sale_online_core(
  p_sales_id uuid,p_master_version bigint,p_posting_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'DEFERRED_PAYMENT_METHOD_NOT_ENABLED';
END
$$;

INSERT INTO public.companies(id,company_code,company_name) VALUES
  ('a59c534b-909f-4b3f-aba0-ae9db6d90b76','KGFF','Kidul Gunung Frozen Food');

INSERT INTO private.kgs_schema_migrations(version) VALUES
  ('20260720090000'),('20260722120000'),('20260722150000'),
  ('20260722180000'),('20261008110000'),('20261008120000'),
  ('20261008130000'),('20261030120000'),('20261030130000'),
  ('20261031100000');

INSERT INTO public.company_features(company_id,feature_code,is_enabled,config)
VALUES ('a59c534b-909f-4b3f-aba0-ae9db6d90b76','ketul_enabled',true,'{}');

INSERT INTO public.product_categories(
  id,company_id,category_code,category_name,is_active
) VALUES (
  '6a66a570-521f-47e9-981e-4fda051df13e',
  'a59c534b-909f-4b3f-aba0-ae9db6d90b76','CAT-000011','KETUL',true
);

INSERT INTO public.uoms(id,company_id,is_active) VALUES
  ('10000000-0000-0000-0000-000000000001',
   'a59c534b-909f-4b3f-aba0-ae9db6d90b76',true);

INSERT INTO public.products(
  id,company_id,category_id,uom_id,sku,name,is_active
) VALUES (
  '20000000-0000-0000-0000-000000000001',
  'a59c534b-909f-4b3f-aba0-ae9db6d90b76',
  '6a66a570-521f-47e9-981e-4fda051df13e',
  '10000000-0000-0000-0000-000000000001','KETUL-1','Ketul Fixture',true
);

INSERT INTO public.system_events(
  system_key,required_account_functions,conditional_account_functions,is_active
) VALUES ('KETUL_CUSTOMER_INTAKE',ARRAY['INVENTORY_ASSET'],ARRAY[]::text[],true);

INSERT INTO public.transaction_categories(
  id,company_id,category_code,system_key,is_active
) VALUES (
  '30000000-0000-0000-0000-000000000001',
  'a59c534b-909f-4b3f-aba0-ae9db6d90b76',
  'DEFAULT-KETUL-CUSTOMER-INTAKE','KETUL_CUSTOMER_INTAKE',true
);

INSERT INTO public.chart_of_accounts(
  id,company_id,account_code,account_name,account_type,normal_balance,
  parent_account_id,system_function_key,is_active,is_postable,is_system_account
) VALUES
  ('40000000-0000-0000-0000-000000000001',
   'a59c534b-909f-4b3f-aba0-ae9db6d90b76','1030100-4','PERSEDIAAN KETUL',
   'ASSET','DEBIT',NULL,NULL,true,true,false),
  ('40000000-0000-0000-0000-000000000002',
   'a59c534b-909f-4b3f-aba0-ae9db6d90b76','2050100-1','CUSTOMER BALANCE',
   'LIABILITY','CREDIT',NULL,'CUSTOMER_BALANCE_LIABILITY',true,true,false);

INSERT INTO public.transaction_account_rules(
  company_id,transaction_category_id,account_function_key,account_id,status,
  effective_from,effective_to
) VALUES (
  'a59c534b-909f-4b3f-aba0-ae9db6d90b76',
  '30000000-0000-0000-0000-000000000001','INVENTORY_ASSET',
  '40000000-0000-0000-0000-000000000001','ACTIVE',clock_timestamp(),NULL
);

\ir ../diagnostics/pos_ketul_customer_intake_offset_preflight.sql

ROLLBACK;

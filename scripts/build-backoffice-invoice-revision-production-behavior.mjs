import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const read = (path) => readFileSync(join(root, path), "utf8").replaceAll("\r\n", "\n");
const replaceOnce = (source, from, to) => {
  if (source.split(from).length !== 2) throw new Error(`UNIQUE_ANCHOR_REQUIRED: ${from.slice(0, 100)}`);
  return source.replace(from, to);
};
const replaceBlock = (source, from, to, replacement) => {
  const start = source.indexOf(from);
  const end = source.indexOf(to, start);
  if (start < 0 || end < 0 || source.indexOf(from, start + 1) >= 0) {
    throw new Error(`UNIQUE_BLOCK_REQUIRED: ${from.slice(0, 100)}`);
  }
  return source.slice(0, start) + replacement + source.slice(end);
};
const withoutTransaction = (source) => replaceOnce(replaceOnce(source, "BEGIN;\n", ""), "ROLLBACK;\n", "");

let posting = read("supabase/tests/backoffice_sales_invoice_posting_runtime_behavior.sql");
let price = read("supabase/tests/backoffice_posted_invoice_price_correction_behavior.sql");
let payment = read("supabase/tests/backoffice_sales_payment_collection_behavior.sql");

// Keep the production ledger assertions, but make the fixture Company explicit
// and require the already-live Backoffice mode. No business assertion is removed.
posting = replaceOnce(posting,
  "  WHERE company.status='ACTIVE'",
  "  WHERE company.status='ACTIVE' AND company.id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid");
posting = replaceBlock(posting,
  "  -- Company-mode preparation is rolled back and cleared before Sales RPCs.",
  "  PERFORM private.assert_sales_process_root_creation_allowed(",
  "  IF NOT EXISTS(SELECT 1 FROM public.company_sales_process_settings WHERE company_id=v_company AND active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: KMS Backoffice mode required'; END IF;\n");
posting = replaceOnce(posting,
  "ORDER BY customer.is_system_customer DESC,customer.id LIMIT 1;",
  "ORDER BY customer.is_system_customer ASC,customer.id LIMIT 1;");
posting = replaceOnce(posting,
  "  UPDATE public.warehouses SET allow_negative_stock=v_original_negative",
  "  PERFORM set_config('mads_test.invoice_revision_behavior_seed',v_regular_id::text,true);\n  PERFORM set_config('mads_test.invoice_revision_amount_taxed',v_regular_id::text,true);\n  UPDATE public.warehouses SET allow_negative_stock=v_original_negative");

price = replaceOnce(price,
  "  WHERE invoice.company_id IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,",
  "  WHERE invoice.id=NULLIF(current_setting('mads_test.invoice_revision_behavior_seed',true),'')::uuid\n    AND invoice.company_id IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,");

payment = replaceOnce(payment,
  "  WHERE company.status='ACTIVE'",
  "  WHERE company.status='ACTIVE' AND company.id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid");
payment = replaceBlock(payment,
  "  -- Prepare the Company-mode prerequisite only inside outer rollback.",
  "  PERFORM private.assert_sales_process_root_creation_allowed(",
  "  IF NOT EXISTS(SELECT 1 FROM public.company_sales_process_settings WHERE company_id=v_company AND active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: KMS Backoffice mode required'; END IF;\n");
payment = replaceOnce(payment,
  "  IF (SELECT count(*) FROM public.customer_receipt_allocations)<>v_retail_alloc_before\n    OR (SELECT count(*) FROM public.sales_headers)<>v_sales_before THEN\n    RAISE EXCEPTION 'TEST_FAILED: Backoffice payment changed Retail allocation or Sales';\n  END IF;",
  "  IF (SELECT count(*) FROM public.customer_receipt_allocations)<>v_retail_alloc_before\n    OR (SELECT count(*) FROM public.sales_headers)<>v_sales_before THEN\n    RAISE EXCEPTION 'TEST_FAILED: Backoffice payment changed Retail allocation or Sales';\n  END IF;\n  PERFORM set_config('mads_test.invoice_revision_amount_untaxed',v_invoice::text,true);");

posting = withoutTransaction(posting);
price = withoutTransaction(price);
payment = withoutTransaction(payment);

let preparationFixture = read("supabase/staging/backoffice_invoice_revision_preparation_fixture.sql");
preparationFixture = replaceOnce(preparationFixture,
  "CREATE TEMP TABLE staging_revision_invoice_fixture(\n  ordinal integer PRIMARY KEY CHECK(ordinal BETWEEN 1 AND 4),\n  invoice_id uuid NOT NULL UNIQUE,\n  fixture_role text NOT NULL UNIQUE\n) ON COMMIT DROP;\n\n",
  "");
preparationFixture = replaceOnce(preparationFixture,
  "  WHERE i.company_id=c AND i.status='POSTED' AND i.invoice_type='REGULAR'\n    AND EXISTS(SELECT 1 FROM public.backoffice_sales_down_payment_applications a",
  "  WHERE i.company_id=c\n    AND i.id=NULLIF(current_setting('mads_test.invoice_revision_behavior_seed',true),'')::uuid\n    AND i.status='POSTED' AND i.invoice_type='REGULAR'\n    AND EXISTS(SELECT 1 FROM public.backoffice_sales_down_payment_applications a");
preparationFixture = replaceOnce(preparationFixture,
  "  INSERT INTO staging_revision_invoice_fixture VALUES(1,target.id,'DP_TARGET');",
  "  PERFORM set_config('mads_test.invoice_revision_fixture_1',target.id::text,true);");
preparationFixture = replaceOnce(preparationFixture,
  "    INSERT INTO staging_revision_invoice_fixture\n    VALUES(v_iteration,v_invoice_id,'UNPAID_SHARED_'||v_iteration);",
  "    PERFORM set_config('mads_test.invoice_revision_fixture_'||v_iteration::text,v_invoice_id::text,true);");

let installedTests = [
  "supabase/tests/backoffice_invoice_revision_amount_preview_behavior.sql",
  "supabase/tests/backoffice_invoice_revision_preparation_behavior.sql",
  "supabase/tests/backoffice_invoice_revision_execution_plan_behavior.sql",
  "supabase/tests/backoffice_invoice_revision_journal_plan_behavior.sql",
  "supabase/tests/backoffice_invoice_revision_writer_behavior.sql",
].map(read).join("\n");
installedTests = replaceOnce(installedTests,
  "  FOR v_invoice IN SELECT * FROM public.backoffice_sales_invoices\n    WHERE company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'\n      AND status='POSTED' AND invoice_type='REGULAR' ORDER BY id LOOP",
  "  FOR v_invoice IN SELECT invoice.*\n    FROM (VALUES\n      (NULLIF(current_setting('mads_test.invoice_revision_amount_taxed',true),'')::uuid,'TAXED_PRICE_CORRECTED'::text),\n      (NULLIF(current_setting('mads_test.invoice_revision_amount_untaxed',true),'')::uuid,'UNTAXED_PAID'::text)\n    ) fixture(invoice_id,fixture_role)\n    JOIN public.backoffice_sales_invoices invoice ON invoice.id=fixture.invoice_id\n    WHERE invoice.company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'\n      AND invoice.status='POSTED' AND invoice.invoice_type='REGULAR'\n    ORDER BY fixture.fixture_role LOOP");

const fixtureIdArray = "ARRAY[\n    NULLIF(current_setting('mads_test.invoice_revision_fixture_1',true),'')::uuid,\n    NULLIF(current_setting('mads_test.invoice_revision_fixture_2',true),'')::uuid,\n    NULLIF(current_setting('mads_test.invoice_revision_fixture_3',true),'')::uuid,\n    NULLIF(current_setting('mads_test.invoice_revision_fixture_4',true),'')::uuid\n  ]";
installedTests = replaceOnce(installedTests,
  "  SELECT array_agg(invoice_id ORDER BY ordinal) INTO ids\n  FROM staging_revision_invoice_fixture;",
  `  ids:=${fixtureIdArray};`);
installedTests = replaceOnce(installedTests,
  "  SELECT array_agg(invoice_id ORDER BY ordinal) INTO ids FROM staging_revision_invoice_fixture;",
  `  ids:=${fixtureIdArray};`);
installedTests = replaceOnce(installedTests,
  "  SELECT i.* INTO STRICT amount_invoice FROM public.backoffice_sales_invoices i\n    JOIN staging_revision_invoice_fixture f ON f.invoice_id=i.id\n    WHERE f.ordinal=2;",
  "  SELECT i.* INTO STRICT amount_invoice FROM public.backoffice_sales_invoices i\n    WHERE i.id=NULLIF(current_setting('mads_test.invoice_revision_fixture_2',true),'')::uuid;");
installedTests = replaceOnce(installedTests,
  "  SELECT i.* INTO STRICT report_invoice FROM public.backoffice_sales_invoices i\n    JOIN staging_revision_invoice_fixture f ON f.invoice_id=i.id\n    WHERE f.ordinal=3;",
  "  SELECT i.* INTO STRICT report_invoice FROM public.backoffice_sales_invoices i\n    WHERE i.id=NULLIF(current_setting('mads_test.invoice_revision_fixture_3',true),'')::uuid;");
installedTests = replaceOnce(installedTests,
  "  SELECT invoice.* INTO STRICT target_invoice\n  FROM public.backoffice_sales_invoices invoice\n  JOIN staging_revision_invoice_fixture fixture ON fixture.invoice_id=invoice.id\n  WHERE fixture.ordinal=3;",
  "  SELECT invoice.* INTO STRICT target_invoice\n  FROM public.backoffice_sales_invoices invoice\n  WHERE invoice.id=NULLIF(current_setting('mads_test.invoice_revision_fixture_3',true),'')::uuid;");

installedTests = replaceBlock(installedTests,
  "CREATE TEMP TABLE staging_revision_auth_command AS",
  "DO $authenticated$",
  `DO $auth_fixture$
DECLARE
  v_invoice_id uuid;v_command jsonb;v_prior_customer uuid;v_new_customer uuid;
  v_report_identity jsonb;v_report_source jsonb;v_customer_name text;v_effective_total numeric;
BEGIN
  SELECT p.invoice_id,p.request_snapshot||jsonb_build_object('operationId',p.operation_id)
  INTO STRICT v_invoice_id,v_command
  FROM private.backoffice_invoice_revision_preparations p
  WHERE p.invoice_id=NULLIF(current_setting('mads_test.invoice_revision_fixture_2',true),'')::uuid
  ORDER BY p.created_at DESC LIMIT 1;
  PERFORM set_config('mads_test.auth_invoice',v_invoice_id::text,true);
  PERFORM set_config('mads_test.auth_command',v_command::text,true);

  SELECT r.invoice_id,r.prior_customer_id,r.new_customer_id,
    private.backoffice_invoice_effective_identity(r.company_id,r.invoice_id,current_date),
    to_jsonb(invoice),customer.name,
    private.backoffice_invoice_effective_total(r.company_id,r.invoice_id,current_date)
  INTO STRICT v_invoice_id,v_prior_customer,v_new_customer,v_report_identity,
    v_report_source,v_customer_name,v_effective_total
  FROM private.backoffice_invoice_revisions r
  JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=r.company_id AND invoice.id=r.invoice_id
  JOIN public.customers customer ON customer.company_id=r.company_id AND customer.id=r.new_customer_id
  WHERE r.company_id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid
    AND r.prior_customer_id<>r.new_customer_id AND r.new_invoice_date<=current_date
  ORDER BY r.posted_at DESC,r.id LIMIT 1;
  PERFORM set_config('mads_test.report_invoice',v_invoice_id::text,true);
  PERFORM set_config('mads_test.report_prior_customer',v_prior_customer::text,true);
  PERFORM set_config('mads_test.report_new_customer',v_new_customer::text,true);
  PERFORM set_config('mads_test.report_identity',v_report_identity::text,true);
  PERFORM set_config('mads_test.report_source',v_report_source::text,true);
  PERFORM set_config('mads_test.report_customer_name',v_customer_name,true);
  PERFORM set_config('mads_test.report_effective_total',v_effective_total::text,true);
END
$auth_fixture$;
SET LOCAL ROLE authenticated;
`);
installedTests = replaceOnce(installedTests,
  " SELECT row.invoice_id,(row.command->>'operationId')::uuid,row.command\n INTO STRICT target_invoice,operation,command FROM staging_revision_auth_command row;",
  " SELECT NULLIF(current_setting('mads_test.auth_invoice',true),'')::uuid,\n   (NULLIF(current_setting('mads_test.auth_command',true),'')::jsonb->>'operationId')::uuid,\n   NULLIF(current_setting('mads_test.auth_command',true),'')::jsonb\n INTO STRICT target_invoice,operation,command;");
installedTests = replaceOnce(installedTests,
  " SELECT invoice_id,prior_customer_id,new_customer_id,row.report_identity,row.report_source,\n   row.report_customer_name,row.report_effective_total\n INTO STRICT report_invoice,old_customer,new_customer,report_identity,report_source,\n   report_customer_name,report_effective_total\n FROM staging_revision_report_target row;",
  " SELECT NULLIF(current_setting('mads_test.report_invoice',true),'')::uuid,\n   NULLIF(current_setting('mads_test.report_prior_customer',true),'')::uuid,\n   NULLIF(current_setting('mads_test.report_new_customer',true),'')::uuid,\n   NULLIF(current_setting('mads_test.report_identity',true),'')::jsonb,\n   NULLIF(current_setting('mads_test.report_source',true),'')::jsonb,\n   current_setting('mads_test.report_customer_name',true),\n   NULLIF(current_setting('mads_test.report_effective_total',true),'')::numeric\n INTO STRICT report_invoice,old_customer,new_customer,report_identity,report_source,\n   report_customer_name,report_effective_total;");

const output = `-- Generated by scripts/build-backoffice-invoice-revision-production-behavior.mjs.
-- Complete rollback-only package. Run only after migration 20261006140000.
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='180s';
SET LOCAL timezone='UTC';

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260909161000','20260911160000','20260911161000',
        '20260911162000','20260911163000','20260917131000','20260917150000',
        '20260925100000','20260928110000','20260929130000','20261006140000'))<>11 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact Invoice revision migration chain required';
  END IF;
  IF to_regprocedure('public.post_backoffice_invoice_revision(jsonb)') IS NULL
    OR to_regprocedure('public.get_backoffice_invoice_revision_context(uuid)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: installed Invoice revision runtime required';
  END IF;
END
$guard$;

${posting}
${price}
${payment}
${preparationFixture}
${installedTests}
ROLLBACK;
SELECT 'backoffice_unified_posted_invoice_revision_behavior' check_name,
  'PASS' status,0::bigint violation_rows,
  jsonb_build_object('tested',ARRAY[
    'canonical Posted Invoice and DP fixture',
    'legacy price correction compatibility',
    'canonical Customer Receipt compatibility',
    'amount and date preview',
    'immutable preparation and shared Receipt/DP snapshot',
    'stable dependency lock and execution plan',
    'balanced journal plan',
    'atomic revision writer and Return/Credit Note consumers',
    'all fixture writes rolled back']) details;
`;

const outputPath = join(root, "supabase/tests/backoffice_unified_posted_invoice_revision_behavior.sql");
writeFileSync(outputPath, output);
process.stdout.write(JSON.stringify({
  status: "GENERATED",
  output: outputPath,
  sha256: createHash("sha256").update(output).digest("hex"),
}));

import { readFileSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";

const root = resolve(import.meta.dirname, "..");
const version = "20261006140000";
const files = [
  "supabase/staging/backoffice_invoice_revision_amount_preview.sql",
  "supabase/staging/backoffice_invoice_revision_preparation.sql",
  "supabase/staging/backoffice_invoice_revision_execution_plan.sql",
  "supabase/staging/backoffice_invoice_revision_journal_plan.sql",
  "supabase/staging/backoffice_invoice_revision_writer.sql",
  "supabase/staging/backoffice_invoice_revision_consumers.sql",
  "supabase/staging/backoffice_invoice_revision_report_consumers.sql",
  "supabase/staging/backoffice_invoice_revision_export_consumer.sql",
  "supabase/staging/backoffice_invoice_revision_return_consumers.sql",
];

const preamble = `-- Guarded additive rollout for unified Posted Backoffice Invoice revision.
-- Production execution is user-owned. The agent may execute this only on the authorized staging project.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
SELECT pg_advisory_xact_lock(hashtextextended('20261006140000:backoffice_invoice_revision',0));
DO $guard$
DECLARE
  required_versions constant text[]:=ARRAY['20260909161000','20260911160000','20260911162000',
    '20260911163000','20260917131000','20260917150000','20260925100000',
    '20260928110000','20260929130000'];
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='${version}') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_INSTALLED: ${version}';
  END IF;
  IF EXISTS(SELECT 1 FROM unnest(required_versions) required(version)
    WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations installed
      WHERE installed.version=required.version)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependency ledger mismatch';
  END IF;
  IF (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF (SELECT count(*) FROM public.companies
      WHERE id IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
        '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
        '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid)
        AND status='ACTIVE')<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: target Company identity';
  END IF;
  IF to_regclass('private.backoffice_invoice_revision_preparations') IS NOT NULL
    OR to_regclass('private.backoffice_invoice_revisions') IS NOT NULL
    OR to_regclass('private.backoffice_invoice_revision_lines') IS NOT NULL
    OR to_regclass('private.backoffice_invoice_revision_settlement_attributions') IS NOT NULL
    OR to_regprocedure('public.post_backoffice_invoice_revision(jsonb)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_invoice_revision_context(uuid)') IS NOT NULL
    OR to_regprocedure('private.backoffice_invoice_effective_total_before_unified_revision(uuid,uuid,date)') IS NOT NULL
    OR to_regprocedure('private.backoffice_invoice_effective_entered_unit_price_before_unified_revision(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('private.backoffice_invoice_effective_line_amounts_before_unified_revision(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: object collision';
  END IF;
  IF md5(pg_get_functiondef('private.backoffice_invoice_effective_total(uuid,uuid,date)'::regprocedure))<>'0a64be9b35ac9fba3db3abcd9ab38fad'
    OR md5(pg_get_functiondef('private.backoffice_invoice_effective_entered_unit_price(uuid,uuid)'::regprocedure))<>'2b9cc8a191cb110e5dc31410a6896e40'
    OR md5(pg_get_functiondef('private.backoffice_invoice_effective_line_amounts(uuid,uuid)'::regprocedure))<>'82f8ce5bb1b4edf39a53cbe5f191666c'
    OR md5(pg_get_functiondef('public.get_backoffice_sales_invoice_ui(uuid)'::regprocedure))<>'835f1723cc9b19db2675f40276ef5cff'
    OR md5(pg_get_functiondef('public.get_backoffice_sales_invoice_payment_context(uuid)'::regprocedure))<>'b8145d8ca6de47227d8a740281fe5238'
    OR md5(pg_get_functiondef('public.get_finance_ar_aging(date,uuid,uuid)'::regprocedure))<>'5b5f98c00338a5aea20ca70d2a783060'
    OR md5(pg_get_functiondef('public.get_finance_customer_statement(uuid,date,date,uuid)'::regprocedure))<>'202555b9f00a53e8fd4f05bc9e77bcc8'
    OR md5(pg_get_functiondef('public.export_sales_documents(date,date)'::regprocedure))<>'66d00e34c458d0ff6dc9fd24374743a2'
    OR md5(pg_get_functiondef('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)'::regprocedure))<>'70ea76646c02618553ab2bc752ae1b33'
    OR md5(pg_get_functiondef('private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)'::regprocedure))<>'a2d1fbd923bc91bbac81cb482198d46b' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Invoice/Finance runtime drift';
  END IF;
END
$guard$;
`;

const footer = `
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('${version}','backoffice_unified_posted_invoice_revision',
  'KMS/LSM/SMS Posted Regular Backoffice Invoice correction for billing Customer, Invoice date, price and discount; append-only revision/journals, effective UI/payment/AR/statement/export/Return consumers; source SO/DO/Invoice/Stock/FIFO immutable; payment-error correction and payout remain separate canonical workflows');
NOTIFY pgrst,'reload schema';
COMMIT;
`;

const body = files.map((file) => `\n-- BEGIN ${file}\n${readFileSync(join(root, file), "utf8").trim()}\n-- END ${file}\n`).join("");
const output = join(root, "supabase/migrations", `${version}_backoffice_unified_posted_invoice_revision.sql`);
writeFileSync(output, preamble + body + footer);
process.stdout.write(JSON.stringify({ status: "GENERATED", output, files: files.length }));

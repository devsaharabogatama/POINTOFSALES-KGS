import { randomBytes, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const target = "yjxpddwrjdczuqyixqwi";
const kms = "4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8";
const sms = "809abdd9-d05f-4525-9726-1951a0ae1a81";
const root = resolve(import.meta.dirname, "..");
const outputPath = resolve(process.argv[2] ?? "");
const capture = dirname(outputPath);
const serverBase = process.env.INVOICE_SMOKE_SERVER_BASE ?? "http://127.0.0.1:3186";
const workdir = join(process.env.TEMP, "mads-invoice-staging-20261005");
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

if (!outputPath.startsWith(resolve(workdir) + "\\") ||
  readFileSync(join(workdir, "supabase/.temp/project-ref"), "utf8").trim() !== target ||
  !process.env.PGUSER?.endsWith(`.${target}`) ||
  process.env.PGHOST !== "aws-0-ap-southeast-1.pooler.supabase.com" ||
  supabaseUrl !== `https://${target}.supabase.co` || !publishableKey || !serviceRoleKey ||
  !/^http:\/\/127\.0\.0\.1:\d+$/.test(serverBase)) {
  throw new Error("AUTHORIZED_STAGING_TARGET_REQUIRED");
}

const requireBackoffice = createRequire(join(root, "backoffice/package.json"));
const { createClient } = requireBackoffice("@supabase/supabase-js");
const requirePg = createRequire(join(workdir, "pg-client/package.json"));
const { Client } = requirePg("pg");
const pg = new Client({ ssl: { rejectUnauthorized: true,
  ca: readFileSync(join(workdir, "supabase-root-ca.crt"), "utf8") }, connectionTimeoutMillis: 15000 });
const admin = createClient(supabaseUrl, serviceRoleKey,
  { auth: { autoRefreshToken: false, persistSession: false } });
const publicClient = createClient(supabaseUrl, publishableKey,
  { auth: { autoRefreshToken: false, persistSession: false } });

function fixtureSql() {
  const baseline = readFileSync(join(capture, "invoice-baseline.sql"), "utf8").replaceAll("\r\n", "\n");
  const fixtureEnd = baseline.indexOf("END $fixture$;");
  if (fixtureEnd < 0 || !baseline.startsWith("BEGIN;")) throw new Error("STAGING_BASE_FIXTURE_REQUIRED");
  const prefix = baseline.slice(0, fixtureEnd + "END $fixture$;".length);
  const behavior = readFileSync(join(root,
    "supabase/tests/backoffice_unified_posted_invoice_revision_behavior.sql"), "utf8").replaceAll("\r\n", "\n");
  const start = behavior.indexOf("CREATE TEMP TABLE invoice_revision_behavior_seed");
  const next = behavior.indexOf("-- Authenticated rollback-only behavior test for posted Invoice price correction.");
  if (start < 0 || next <= start) throw new Error("CANONICAL_POSTING_FIXTURE_BOUNDARY_INVALID");
  const posting = behavior.slice(start, next);
  return `${prefix}\n` +
    "INSERT INTO private.kgs_schema_migrations(version,migration_name,notes) VALUES\n" +
    "('20260909161000','STAGING_SMOKE_METADATA_ONLY','Removed before commit'),\n" +
    "('20260925100000','STAGING_SMOKE_METADATA_ONLY','Removed before commit')\n" +
    "ON CONFLICT(version) DO NOTHING;\n" + posting +
    "DELETE FROM private.kgs_schema_migrations WHERE migration_name='STAGING_SMOKE_METADATA_ONLY';\n" +
    "SELECT invoice_id smoke_invoice_id FROM invoice_revision_behavior_seed;\nCOMMIT;\n";
}

async function api(path, init = {}, expected = 200) {
  const response = await fetch(`${serverBase}${path}`, init);
  const text = await response.text();
  let payload;
  try { payload = text ? JSON.parse(text) : null; } catch { payload = { raw: text }; }
  if (response.status !== expected) {
    throw new Error(`HTTP_${response.status}_EXPECTED_${expected}:${path}:${JSON.stringify(payload)}`);
  }
  return payload;
}

function decimalPlusOne(value) {
  const [whole, fraction = ""] = String(value).split(".");
  return `${BigInt(whole) + 1n}.${fraction.padEnd(4, "0").slice(0, 4)}`;
}

let smokeUserId = null;
let membershipId = null;
let token = null;
let invoiceId = null;
const checks = [];
try {
  await pg.connect();
  await pg.query("SET ROLE postgres");
  invoiceId = (await pg.query({ text: `SELECT i.id FROM public.backoffice_sales_invoices i
      JOIN public.customers c ON c.company_id=i.company_id AND c.id=i.customer_id
      WHERE i.company_id=$1 AND i.status='POSTED' AND i.invoice_type='REGULAR'
        AND c.code='STAGING-INVOICE-CUSTOMER' AND NOT i.return_adjustment_pending_confirmation
        AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes n
          WHERE n.company_id=i.company_id AND n.source_invoice_id=i.id AND n.status IN('DRAFT','POSTED'))
      ORDER BY i.created_at DESC LIMIT 1`, values: [kms] })).rows[0]?.id ?? null;
  if (!invoiceId) {
    const fixtureResult = await pg.query(fixtureSql());
    const resultSets = Array.isArray(fixtureResult) ? fixtureResult : [fixtureResult];
    invoiceId = resultSets.flatMap((item) => item.rows ?? [])
      .find((row) => row.smoke_invoice_id)?.smoke_invoice_id ?? null;
    if (!invoiceId) throw new Error("STAGING_SMOKE_INVOICE_NOT_CREATED");
    checks.push("canonical Posted Backoffice Invoice fixture created on staging");
  } else {
    checks.push("existing canonical staging Invoice fixture reused safely");
  }

  const before = (await pg.query({ text: `SELECT to_jsonb(i) invoice,
      (SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.backoffice_sales_invoice_lines l
       WHERE l.company_id=i.company_id AND l.invoice_id=i.id) lines
    FROM public.backoffice_sales_invoices i WHERE i.company_id=$1 AND i.id=$2`, values: [kms, invoiceId] })).rows[0];
  if (!before) throw new Error("STAGING_SMOKE_INVOICE_MISSING");

  const suffix = `${Date.now()}-${randomBytes(4).toString("hex")}`;
  const email = `invoice-revision-smoke-${suffix}@example.invalid`;
  const password = `${randomBytes(24).toString("base64url")}A1!`;
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true,
    user_metadata: { name: "Invoice Revision Staging Smoke" } });
  if (created.error || !created.data.user) throw created.error ?? new Error("SMOKE_AUTH_USER_CREATE_FAILED");
  smokeUserId = created.data.user.id;
  let response = await admin.from("profiles").upsert({ id: smokeUserId, email,
    name: "Invoice Revision Staging Smoke", role: "cashier" });
  if (response.error) throw response.error;
  response = await admin.from("company_memberships").insert({ company_id: kms, user_id: smokeUserId,
    role_code: "COMPANY_ADMIN", status: "ACTIVE", is_default_company: true }).select("id").single();
  if (response.error) throw response.error;
  membershipId = response.data.id;
  response = await admin.from("user_active_company_contexts").insert({ user_id: smokeUserId,
    company_id: kms, selection_source: "STAGING_SMOKE" });
  if (response.error) throw response.error;
  const signIn = await publicClient.auth.signInWithPassword({ email, password });
  if (signIn.error || !signIn.data.session?.access_token) throw signIn.error ?? new Error("SMOKE_SIGN_IN_FAILED");
  token = signIn.data.session.access_token;
  const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  checks.push("temporary authenticated Company Admin session established");

  await api(`/api/sales/backoffice-invoices/${invoiceId}`, {}, 401);
  checks.push("unauthenticated Invoice read rejected");
  const detail = await api(`/api/sales/backoffice-invoices/${invoiceId}`, { headers });
  const context = detail.revisionContext;
  if (!context?.canCorrect || !Array.isArray(context.lines) || context.lines.length < 1 ||
    context.invoiceId !== invoiceId || detail.data?.status !== "POSTED") {
    throw new Error(`AUTHENTICATED_INVOICE_CONTEXT_INVALID:${JSON.stringify(detail)}`);
  }
  checks.push("authenticated Invoice detail exposes revision context");

  const operationId = randomUUID();
  const originalRevision = Number(context.revision);
  const originalHistoryRows = context.history.length;
  const firstId = context.lines[0].invoiceLineId;
  const command = { kind: "INVOICE_REVISION", invoiceId, operationId,
    masterVersion: Number(context.masterVersion), revision: originalRevision, notes: null,
    customerId: context.effectiveIdentity.customerId,
    invoiceDate: context.effectiveIdentity.invoiceDate, dueDate: { mode: "KEEP_TERM" },
    lines: context.lines.map((line) => ({ invoiceLineId: line.invoiceLineId,
      unitPrice: line.invoiceLineId === firstId
        ? decimalPlusOne(line.effectiveAmounts.enteredUnitPrice)
        : Number(line.effectiveAmounts.enteredUnitPrice).toFixed(4),
      discountAmount: Number(line.effectiveAmounts.discountAmount).toFixed(4) })) };
  const posted = await api(`/api/sales/backoffice-invoices/${invoiceId}/revisions`,
    { method: "POST", headers, body: JSON.stringify(command) });
  if (posted.exactRetry !== false || Number(posted.revision) !== originalRevision + 1) {
    throw new Error(`REVISION_POST_RESPONSE_INVALID:${JSON.stringify(posted)}`);
  }
  const retry = await api(`/api/sales/backoffice-invoices/${invoiceId}/revisions`,
    { method: "POST", headers, body: JSON.stringify(command) });
  if (retry.exactRetry !== true || retry.revision !== posted.revision) {
    throw new Error(`REVISION_EXACT_RETRY_INVALID:${JSON.stringify(retry)}`);
  }
  checks.push("revision POST and exact idempotent retry passed through Next API");

  const afterDetail = await api(`/api/sales/backoffice-invoices/${invoiceId}`, { headers });
  if (Number(afterDetail.revisionContext?.revision) !== originalRevision + 1 ||
    afterDetail.revisionContext?.history?.length !== originalHistoryRows + 1 ||
    afterDetail.data?.invoiceRevision !== originalRevision + 1 ||
    Number(afterDetail.data?.effectiveGrandTotal) !== Number(posted.effectiveTotal)) {
    throw new Error(`EFFECTIVE_RELOAD_INVALID:${JSON.stringify(afterDetail)}`);
  }
  checks.push("effective Invoice reader and revision history reload passed");

  response = await admin.from("user_active_company_contexts").update({ company_id: sms,
    selection_source: "STAGING_SMOKE_TENANT_NEGATIVE", updated_at: new Date().toISOString() })
    .eq("user_id", smokeUserId);
  if (response.error) throw response.error;
  const cross = await fetch(`${serverBase}/api/sales/backoffice-invoices/${invoiceId}`, { headers });
  if (cross.ok) throw new Error("CROSS_COMPANY_INVOICE_READ_ALLOWED");
  response = await admin.from("user_active_company_contexts").update({ company_id: kms,
    selection_source: "STAGING_SMOKE_RESTORED", updated_at: new Date().toISOString() })
    .eq("user_id", smokeUserId);
  if (response.error) throw response.error;
  checks.push("cross-Company Invoice read rejected");

  const after = (await pg.query({ text: `SELECT to_jsonb(i) invoice,
      (SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id) FROM public.backoffice_sales_invoice_lines l
       WHERE l.company_id=i.company_id AND l.invoice_id=i.id) lines
    FROM public.backoffice_sales_invoices i WHERE i.company_id=$1 AND i.id=$2`, values: [kms, invoiceId] })).rows[0];
  const finance = (await pg.query({ text: `SELECT r.revision_no,r.actor_id,r.journal_ids,
      (SELECT bool_and(j.status='POSTED' AND j.total_debit=j.total_credit)
       FROM jsonb_array_elements_text(r.journal_ids) item(journal_id)
       JOIN public.finance_journals j ON j.company_id=r.company_id
         AND j.id=item.journal_id::uuid) balanced
    FROM private.backoffice_invoice_revisions r
    WHERE r.company_id=$1 AND r.invoice_id=$2 AND r.actor_id=$3`,
    values: [kms, invoiceId, smokeUserId] })).rows;
  if (JSON.stringify(before.invoice) !== JSON.stringify(after.invoice) ||
    JSON.stringify(before.lines) !== JSON.stringify(after.lines) || finance.length !== 1 ||
    finance[0].actor_id !== smokeUserId || finance[0].balanced !== true) {
    throw new Error(`DATABASE_POSTCONDITION_INVALID:${JSON.stringify({ finance })}`);
  }
  checks.push("source Invoice/lines immutable and revision journals posted balanced");

  const receipt = { target, checkedAt: new Date().toISOString(),
    status: "AUTHENTICATED_STAGING_API_SMOKE_PASS", invoiceId,
    serverBase, checks, browserVisualSmoke: "NOT_RUN_BROWSER_CONNECTOR_UNAVAILABLE" };
  writeFileSync(outputPath, JSON.stringify(receipt, null, 2));
  process.stdout.write(JSON.stringify(receipt));
} catch (error) {
  const failure = { target, checkedAt: new Date().toISOString(),
    status: "AUTHENTICATED_STAGING_API_SMOKE_FAILED", invoiceId, checks,
    code: error?.code, message: error?.message, details: error?.details, hint: error?.hint };
  writeFileSync(outputPath.replace(/\.json$/, `-failure-${Date.now()}.json`), JSON.stringify(failure, null, 2));
  console.error(JSON.stringify(failure));
  process.exitCode = 1;
} finally {
  if (smokeUserId) {
    try {
      if (membershipId) await admin.from("company_memberships").update({ status: "INACTIVE",
        is_default_company: false }).eq("id", membershipId);
      await admin.auth.admin.signOut(smokeUserId, "global");
      await admin.auth.admin.updateUserById(smokeUserId, { ban_duration: "876000h" });
    } catch (cleanupError) {
      console.error(JSON.stringify({ status: "SMOKE_ACTOR_DEACTIVATION_FAILED",
        message: cleanupError?.message }));
      process.exitCode = 1;
    }
  }
  if (token) await publicClient.auth.signOut();
  try { await pg.end(); } catch {}
}

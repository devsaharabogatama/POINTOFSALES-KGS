import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";

const target = "yjxpddwrjdczuqyixqwi";
const outputPath = resolve(process.argv[2] ?? "");
const mode = process.argv[3] ?? "";
const capture = dirname(outputPath);
const workdir = join(process.env.TEMP, "mads-invoice-staging-20261005");
const root = resolve(import.meta.dirname, "..");
if (mode !== "Rehearse" || !outputPath.startsWith(resolve(workdir) + "\\") ||
  readFileSync(join(workdir, "supabase/.temp/project-ref"), "utf8").trim() !== target ||
  !process.env.PGUSER?.endsWith(`.${target}`) ||
  process.env.PGHOST !== "aws-0-ap-southeast-1.pooler.supabase.com") {
  throw new Error("STAGING_ROLLBACK_ONLY");
}

const baseline = readFileSync(join(capture, "invoice-baseline.sql"), "utf8").replaceAll("\r\n", "\n");
const fixtureEnd = baseline.indexOf("END $fixture$;");
if (fixtureEnd < 0) throw new Error("STAGING_BASE_FIXTURE_REQUIRED");
const prefix = baseline.slice(0, fixtureEnd + "END $fixture$;".length);
const behaviorPath = join(root, "supabase/tests/backoffice_unified_posted_invoice_revision_behavior.sql");
const behavior = readFileSync(behaviorPath, "utf8").replaceAll("\r\n", "\n");
if (behavior.split("BEGIN;\n").length !== 2 || !behavior.includes("all fixture writes rolled back")) {
  throw new Error("PRODUCTION_BEHAVIOR_BOUNDARY_INVALID");
}
const missingMetadata = ["20260909161000", "20260911160000", "20260911161000",
  "20260911162000", "20260911163000", "20260917131000", "20260917150000", "20260925100000",
  "20260928110000", "20260929130000"];
const metadataFixture = missingMetadata.map((version) =>
  `INSERT INTO private.kgs_schema_migrations(version,migration_name,notes) VALUES('${version}','STAGING_ROLLBACK_METADATA_ONLY','Rolled back Production behavior validation metadata') ON CONFLICT(version) DO NOTHING;`).join("\n");
const hash = createHash("sha256").update(behavior).digest("hex");
const require = createRequire(join(workdir, "pg-client/package.json"));
const { Client } = require("pg");
const client = new Client({ ssl: { rejectUnauthorized: true,
  ca: readFileSync(join(workdir, "supabase-root-ca.crt"), "utf8") }, connectionTimeoutMillis: 15000 });
const quote = (value) => `"${value.replaceAll('"', '""')}"`;

try {
  await client.connect();
  await client.query("SET ROLE postgres");
  const stagingReady = (await client.query(`SELECT EXISTS(
    SELECT 1 FROM public.companies c
    JOIN public.company_sales_process_settings s ON s.company_id=c.id
    WHERE c.id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid
      AND c.status='ACTIVE' AND s.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE') ready`)).rows[0].ready;
  const sql = `${stagingReady ? "BEGIN;" : prefix}\n${metadataFixture}\n${behavior.replace("BEGIN;\n", "")}`;
  const tables = (await client.query("SELECT n.nspname s,c.relname t FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE (n.nspname IN('public','private') OR (n.nspname='auth' AND c.relname='users')) AND c.relkind='r' ORDER BY 1,2")).rows;
  if (tables.length !== 312) throw new Error("INSTALLED_STAGING_TABLE_COUNT_MISMATCH");
  const fingerprintSql = tables.map(({ s, t }) =>
    `SELECT '${s}.${t}' k,count(*)::int n,md5(COALESCE(string_agg(h,'' ORDER BY h),'')) d FROM (SELECT md5(to_jsonb(x)::text) h FROM ${quote(s)}.${quote(t)} x) q`).join(" UNION ALL ");
  const before = (await client.query(fingerprintSql)).rows;
  let result;
  try { result = await client.query(sql); } finally { await client.query("ROLLBACK"); }
  const after = (await client.query(fingerprintSql)).rows;
  if (JSON.stringify(before) !== JSON.stringify(after)) throw new Error("PRODUCTION_BEHAVIOR_ROLLBACK_MISMATCH");
  const rows = (Array.isArray(result) ? result : [result]).flatMap((entry) => entry.rows);
  const passes = rows.filter((row) => row.status === "PASS");
  if (passes.length !== 9 || !passes.some((row) =>
      row.check_name === "backoffice_unified_posted_invoice_revision_behavior")) {
    throw new Error("PRODUCTION_BEHAVIOR_EXPECTED_RESULTS_MISSING");
  }
  const receipt = { target, checkedAt: new Date().toISOString(), status: "PRODUCTION_BEHAVIOR_PACKAGE_STAGING_PASS_ROLLED_BACK",
    behaviorHash: hash, preservedTables: tables.length,
    checks: passes.map(({ check_name, status, violation_rows }) => ({ check_name, status, violation_rows })) };
  writeFileSync(outputPath, JSON.stringify(receipt, null, 2));
  process.stdout.write(JSON.stringify(receipt));
} catch (error) {
  try { await client.query("ROLLBACK"); } catch {}
  const failure = { target, checkedAt: new Date().toISOString(), status: "PRODUCTION_BEHAVIOR_PACKAGE_STAGING_FAILED_ROLLED_BACK",
    behaviorHash: hash, code: error.code, message: error.message, context: error.where };
  writeFileSync(outputPath.replace(/\.json$/, `-failure-${Date.now()}.json`), JSON.stringify(failure, null, 2));
  console.error(JSON.stringify(failure));
  process.exitCode = 1;
} finally {
  await client.end();
}

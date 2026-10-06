import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";

const target = "yjxpddwrjdczuqyixqwi";
const root = resolve(import.meta.dirname, "..");
const capture = dirname(resolve(process.argv[2] ?? ""));
const mode = process.argv[3] ?? "Rehearse";
const workdir = join(process.env.TEMP, "mads-invoice-staging-20261005");
if (!resolve(process.argv[2] ?? "").startsWith(resolve(workdir) + "\\") ||
  readFileSync(join(workdir, "supabase/.temp/project-ref"), "utf8").trim() !== target ||
  !process.env.PGUSER?.endsWith(`.${target}`) ||
  process.env.PGHOST !== "aws-0-ap-southeast-1.pooler.supabase.com") {
  throw new Error("STAGING_TARGET_REQUIRED");
}
if (!["Rehearse", "Apply", "Verify"].includes(mode)) throw new Error("INVALID_MODE");

const paths = {
  preflight: join(root, "supabase/diagnostics/backoffice_unified_posted_invoice_revision_preflight.sql"),
  migration: join(root, "supabase/migrations/20261006140000_backoffice_unified_posted_invoice_revision.sql"),
  postflight: join(root, "supabase/diagnostics/backoffice_unified_posted_invoice_revision_postflight.sql"),
};
const sql = Object.fromEntries(Object.entries(paths).map(([key, path]) => [key, readFileSync(path, "utf8")]));
const hashes = Object.fromEntries(Object.entries(sql).map(([key, value]) =>
  [key, createHash("sha256").update(value).digest("hex")]));
const require = createRequire(join(workdir, "pg-client/package.json"));
const { Client } = require("pg");
const client = new Client({ ssl: { rejectUnauthorized: true,
  ca: readFileSync(join(workdir, "supabase-root-ca.crt"), "utf8") }, connectionTimeoutMillis: 15000 });

const rowsOf = (result) => (Array.isArray(result) ? result : [result]).flatMap((entry) => entry.rows);
const assertChecks = (rows, forbidden) => {
  const failed = rows.filter((row) => forbidden.includes(row.status));
  if (failed.length) throw Object.assign(new Error("INVOICE_REVISION_ROLLOUT_CHECK_FAILED"), { checks: failed });
  return rows.filter((row) => row.check_name);
};
const assertStagingPreflight = (rows) => {
  const checks = rows.filter((row) => row.check_name);
  const ledger = checks.find((row) => row.check_name === "invoice_revision_dependency_ledger");
  const runtime = checks.find((row) => row.check_name === "invoice_revision_runtime_anchor");
  const otherFailed = checks.filter((row) => ["BLOCKER", "FAIL"].includes(row.status) && row !== ledger);
  if (otherFailed.length || runtime?.status !== "PASS" || ledger?.status !== "BLOCKER" ||
    !Array.isArray(ledger.details?.missing) || ledger.details.missing.length !== 9) {
    throw Object.assign(new Error("INVOICE_REVISION_ROLLOUT_CHECK_FAILED"),
      { checks: [...otherFailed, ...(ledger?.status === "PASS" ? [] : [ledger])] });
  }
  return checks.map((row) => row === ledger ? { ...row,
    status: "STAGING_METADATA_ABSENT",
    details: { ...row.details, rule: "Production remains BLOCKER; staging uses exact runtime digest anchors without fabricating historical ledger rows" } } : row);
};
const dependencyGuard = `IF EXISTS(SELECT 1 FROM unnest(required_versions) required(version)
    WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations installed
      WHERE installed.version=required.version)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependency ledger mismatch';
  END IF;`;
const stagingDependencyGuard = `IF EXISTS(SELECT 1 FROM unnest(required_versions) required(version)
    WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations installed
      WHERE installed.version=required.version)) THEN
    RAISE NOTICE 'STAGING_ONLY: historical dependency ledger metadata absent; exact runtime digests were required by the preceding guard';
  END IF;`;
if (sql.migration.split(dependencyGuard).length !== 2) throw new Error("UNIQUE_DEPENDENCY_GUARD_REQUIRED");
const stagingMigration = sql.migration.replace(dependencyGuard, stagingDependencyGuard);
hashes.stagingMigration = createHash("sha256").update(stagingMigration).digest("hex");

try {
  await client.connect();
  await client.query("SET ROLE postgres");
  let checks;
  if (mode === "Rehearse") {
    await client.query("BEGIN READ ONLY");
    checks = assertStagingPreflight(rowsOf(await client.query(sql.preflight)));
    await client.query("ROLLBACK");
  } else if (mode === "Apply") {
    await client.query("BEGIN READ ONLY");
    checks = assertStagingPreflight(rowsOf(await client.query(sql.preflight)));
    await client.query("ROLLBACK");
    await client.query(stagingMigration);
    checks = assertChecks(rowsOf(await client.query(sql.postflight)), ["BLOCKER", "FAIL"]);
  } else {
    await client.query("BEGIN READ ONLY");
    checks = assertChecks(rowsOf(await client.query(sql.postflight)), ["BLOCKER", "FAIL"]);
    await client.query("ROLLBACK");
  }
  const receipt = { target, mode, hashes, checkedAt: new Date().toISOString(), checks,
    status: mode === "Apply" ? "STAGING_INVOICE_REVISION_DATABASE_LIVE" :
      mode === "Verify" ? "STAGING_INVOICE_REVISION_POSTFLIGHT_PASS" :
        "STAGING_INVOICE_REVISION_PREFLIGHT_PASS" };
  writeFileSync(join(capture, `invoice-revision-${mode.toLowerCase()}-receipt.json`), JSON.stringify(receipt, null, 2));
  process.stdout.write(JSON.stringify(receipt));
} catch (error) {
  try { await client.query("ROLLBACK"); } catch {}
  const failure = { target, mode, hashes, checkedAt: new Date().toISOString(),
    status: "STAGING_INVOICE_REVISION_ROLLOUT_FAILED", code: error.code,
    message: error.message, context: error.where, checks: error.checks };
  writeFileSync(join(capture, `invoice-revision-${mode.toLowerCase()}-failure-${Date.now()}.json`), JSON.stringify(failure, null, 2));
  console.error(JSON.stringify(failure));
  process.exitCode = 1;
} finally {
  await client.end();
}

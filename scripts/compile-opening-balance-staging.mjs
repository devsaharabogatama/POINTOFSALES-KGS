import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const target = "yjxpddwrjdczuqyixqwi";
const expectedHost = "aws-0-ap-southeast-1.pooler.supabase.com";
if (!process.env.PGUSER?.endsWith(`.${target}`) || process.env.PGHOST !== expectedHost) {
  throw new Error("STAGING_CONNECTION_REQUIRED");
}
const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const file = resolve(root, "supabase/migrations/20261029100000_opening_balance_direct_entry.sql");
const migration = readFileSync(file, "utf8");
const start = migration.indexOf("CREATE SEQUENCE private.opening_balance_no_seq");
const end = migration.indexOf("INSERT INTO private.kgs_schema_migrations", start);
if (start < 0 || end < 0) throw new Error("MIGRATION_BODY_NOT_FOUND");
const body = migration.slice(start, end);
const workdir = join(process.env.TEMP, "mads-invoice-staging-20261005");
const require = createRequire(join(workdir, "pg-client", "package.json"));
const { Client } = require("pg");
const certificatePath = join(workdir, "supabase-root-ca.crt");
const client = new Client({
  ssl: existsSync(certificatePath)
    ? { rejectUnauthorized: true, ca: readFileSync(certificatePath, "utf8") }
    : { rejectUnauthorized: true },
  connectionTimeoutMillis: 15000,
});
try {
  await client.connect();
  await client.query("SET ROLE postgres");
  await client.query("BEGIN");
  await client.query(body);
  await client.query("ROLLBACK");
  process.stdout.write(JSON.stringify({ target, status: "STAGING_SCHEMA_COMPILE_PASS" }, null, 2));
} catch (error) {
  await client.query("ROLLBACK").catch(() => {});
  throw error;
} finally {
  await client.end();
}

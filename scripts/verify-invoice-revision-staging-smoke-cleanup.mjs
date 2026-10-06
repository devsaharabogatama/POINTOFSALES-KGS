import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";

const target = "yjxpddwrjdczuqyixqwi";
const outputPath = resolve(process.argv[2] ?? "");
const workdir = join(process.env.TEMP, "mads-invoice-staging-20261005");
if (!outputPath.startsWith(resolve(workdir) + "\\") ||
  readFileSync(join(workdir, "supabase/.temp/project-ref"), "utf8").trim() !== target ||
  !process.env.PGUSER?.endsWith(`.${target}`) ||
  process.env.PGHOST !== "aws-0-ap-southeast-1.pooler.supabase.com") {
  throw new Error("AUTHORIZED_STAGING_TARGET_REQUIRED");
}
const require = createRequire(join(workdir, "pg-client/package.json"));
const { Client } = require("pg");
const client = new Client({ ssl: { rejectUnauthorized: true,
  ca: readFileSync(join(workdir, "supabase-root-ca.crt"), "utf8") }, connectionTimeoutMillis: 15000 });
try {
  await client.connect();
  await client.query("SET ROLE postgres");
  const result = await client.query(`SELECT count(*)::int actors,
    count(*) FILTER(WHERE membership.status='ACTIVE')::int active_memberships,
    count(*) FILTER(WHERE auth_user.banned_until IS NULL OR auth_user.banned_until<=clock_timestamp())::int unbanned_auth_users
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  LEFT JOIN public.company_memberships membership ON membership.user_id=profile.id
  WHERE profile.email LIKE 'invoice-revision-smoke-%@example.invalid'`);
  const row = result.rows[0];
  if (row.actors < 1 || row.active_memberships !== 0 || row.unbanned_auth_users !== 0) {
    throw new Error(`STAGING_SMOKE_ACTOR_NOT_DEACTIVATED:${JSON.stringify(row)}`);
  }
  const receipt = { target, checkedAt: new Date().toISOString(),
    status: "STAGING_SMOKE_ACTORS_DEACTIVATED", ...row };
  writeFileSync(outputPath, JSON.stringify(receipt, null, 2));
  process.stdout.write(JSON.stringify(receipt));
} finally {
  await client.end();
}

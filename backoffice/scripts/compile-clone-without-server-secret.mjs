// Build only: no HTTP server or privileged credential, no file/env/link rewrites.
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const cloneRef = 'idrufihckscppsyclmsu';
if (process.env.MADS_SUPABASE_PROJECT_REF !== cloneRef ||
    process.env.NEXT_PUBLIC_SUPABASE_URL !== `https://${cloneRef}.supabase.co`) {
  throw new Error('CLONE_COMPILE_ENVIRONMENT_GUARD_FAILED');
}
const result = spawnSync(process.execPath, [require.resolve('next/dist/bin/next'), 'build'], {
  stdio: 'inherit',
  env: { ...process.env, SUPABASE_SERVICE_ROLE_KEY: '' },
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);

# Backoffice Sales Local Development Environment

**Status:** LOCAL POSTGRES READY; FULL SUPABASE LOCAL BLOCKED BY MISSING DOCKER  
**Date:** 2026-09-08  
**Production impact:** none

## Outcome

Menyediakan environment database lokal terisolasi untuk pengembangan optional
Backoffice delivered-quantity Sales tanpa memakai Supabase/database aktif.

## Verified environment

- Supabase CLI `2.107.0` tersedia melalui `supabase.cmd`.
- Wrapper PowerShell `supabase.ps1` tidak dapat dijalankan karena execution
  policy; gunakan `supabase.cmd`.
- PostgreSQL `18.4` binaries tersedia di
  `C:\Program Files\PostgreSQL\18\bin`.
- Cluster lokal berada di `.local-dev/postgres-data` dan di-ignore Git.
- Database `mads_backoffice_local` menerima koneksi hanya pada
  `127.0.0.1:55432`.
- Database aplikasi lokal masih kosong; belum ada migration MADS.
- Docker Desktop, Docker CLI, Podman, dan full Supabase local stack belum
  tersedia.
- Repository belum mempunyai `supabase/config.toml`.

## Isolation contract

- Jangan menjalankan `supabase link`, `supabase db push`, atau command remote.
- Jangan memakai URL, anon key, service-role key, atau dump data production.
- Jangan mengubah `backoffice/.env.local` atau `pwa/.env` yang sedang dipakai.
- Env local baru harus terpisah dan tetap di-ignore.
- Bind database hanya ke loopback dengan port nonstandar `55432`.
- Feature Backoffice Sales tetap OFF sampai seluruh local UAT lulus.

## Current limitation

Plain PostgreSQL hanya dapat menjadi parser/schema harness terbatas. Migration
repository bergantung pada Supabase roles, `auth.users`, `auth.uid()`, Storage,
RLS, JWT request context, PostgREST, dan Auth. Repository memiliki lebih dari
200 migration files yang merujuk dependency Supabase tersebut.

Jangan membuat stub auth/storage lalu menganggap hasilnya sebagai authenticated
Supabase behavioral evidence. Full database/RPC/RLS/API/client smoke memerlukan
Supabase local stack, yang pada Windows memerlukan Docker-compatible runtime.

## Next safe step

1. Dengan persetujuan user, install dan start Docker Desktop.
2. Jalankan `supabase.cmd init` secara guarded untuk menambah local config tanpa
   link ke project remote.
3. Jalankan `supabase.cmd start` dan catat URL/key local saja.
4. Verifikasi project ref/URL tidak sama dengan production.
5. Jalankan migration chain pada local reset dan hentikan pada error pertama.
6. Buat fixture dummy/sanitized, lalu baseline regression POS.

## Stop local PostgreSQL

Saat cluster parser-only tidak dibutuhkan:

```powershell
& 'C:\Program Files\PostgreSQL\18\bin\pg_ctl.exe' `
  -D '.local-dev/postgres-data' stop
```

Folder `.local-dev` boleh dibuang hanya setelah server berhenti dan resolved
path terbukti berada di workspace. Tidak ada cleanup otomatis pada runbook ini.


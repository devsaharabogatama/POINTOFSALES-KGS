# PRD-1 Vercel Preview Environment Readiness

## Project split

Buat dua Vercel project dari repository yang sama setelah ACP-7 authenticated
matrix dan PRD-1 SQL preflight PASS:

- Backoffice root directory: `backoffice`;
- PWA root directory: `pwa`.

Preview bukan Production. Jangan aktifkan production domain, production data,
atau automatic Finance posting dari tahap ini.

## Environment variable

### Backoffice

- `NEXT_PUBLIC_SUPABASE_URL`: public project URL;
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`: publishable/anon client key;
- `SUPABASE_SERVICE_ROLE_KEY`: server-only; tidak boleh memakai prefix
  `NEXT_PUBLIC_`, tidak boleh masuk log/client/repository.

### PWA

- `VITE_SUPABASE_URL`: public project URL;
- `VITE_SUPABASE_ANON_KEY`: publishable/anon client key.

Semua `VITE_*` masuk client bundle dan tidak boleh berisi service-role/secret.
Gunakan `.env.example` hanya sebagai daftar nama; nilai nyata disimpan di
Vercel Project Settings.

## Auth dan domain

Tambahkan URL Preview yang benar ke Supabase Auth redirect allowlist. Verifikasi:

- login/logout Backoffice;
- login/logout PWA;
- redirect tidak kembali ke localhost;
- switch Company tetap mempertahankan identity, bukan data cache Company lama;
- link/logo branding dapat dimuat dari origin Preview.

## Finance worker boundary

`/api/worker/process-queue` adalah legacy retired endpoint (`410`) dan tidak
boleh dijadwalkan. `backoffice/vercel.json` sengaja tidak mempunyai Cron.
Controlled Finance queue tetap dijalankan melalui workflow guarded yang sudah
disetujui, bukan cron otomatis.

Vercel Cron memakai HTTP `GET` ke path production dan hanya berjalan pada
production deployment. Karena endpoint lama hanya memiliki `POST` retired
handler, schedule lama akan menjadi invocation gagal/sia-sia dan sudah dihapus.

## Bukti sebelum Preview dinyatakan siap

- Backoffice/PWA build PASS;
- 0 suspect secret pada tracked files dan client asset;
- Preview domain dan Auth redirect smoke PASS;
- navigation/API/RPC role denial parity PASS;
- Storage branding upload/replace/remove + cache smoke PASS;
- PWA install/service-worker/offline retained queue smoke PASS;
- tidak ada Cron legacy di project configuration.

Referensi resmi Vercel:

- https://vercel.com/docs/cron-jobs
- https://vercel.com/docs/project-configuration/vercel-json

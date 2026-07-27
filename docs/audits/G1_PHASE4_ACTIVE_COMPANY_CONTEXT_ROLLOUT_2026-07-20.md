# Evidence G1 Fase 4 — Active Company Context

**Tanggal:** 2026-07-20  
**Requirement:** TEN-001, TEN-002  
**Status:** COMPLETE; database dan authenticated UI initialization PASS.

## Database Evidence

- Preflight, migration `20260720180000`, postflight 13 check, dan behavioral test dikonfirmasi PASS oleh user.
- Active Company selection terbukti authorized, audited, dan idempotent melalui behavioral test.
- Raw output SQL tidak disimpan di repository; status database berasal dari konfirmasi rollout user.

## Application Integration

- `GET /api/me/context` mengembalikan server-side `activeCompanyId`.
- `POST /api/me/active-company` menjadi satu pintu selector Backoffice ke RPC `set_active_company_context`.
- Server context memiliki prioritas atas `localStorage`; local storage hanya fallback/cache.
- UI baru mengganti Company setelah RPC mengonfirmasi ID yang sama. Kegagalan mempertahankan Company lama dan menampilkan notice.
- Supabase/PostgREST error message sekarang dipertahankan oleh API error normalizer.

## Verification Agent

- Backoffice ESLint: 0 error, 1 warning legacy `Truck` unused.
- Backoffice production build: PASS.
- TypeScript `--noEmit`: PASS.
- Local HTTP smoke: `/` = 200; kedua endpoint context tanpa token = 401.
- Browser automation tidak tersedia pada environment agent, sehingga switch Company dengan sesi login tetap manual.

## Authenticated Evidence

Backoffice berhasil menulis satu context untuk Company KGS dengan `selection_source = BACKOFFICE_INIT`; `selected_at` dan `updated_at` konsisten. User mengirim hasil query context pada 2026-07-20. Environment baru memiliki satu Company, sehingga cross-Company selector visual belum dapat diuji tanpa fixture tambahan.

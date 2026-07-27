# Runbook G1 Fase 4 — Active Company Context

**Migration:** `supabase/migrations/20260720180000_g1_phase4_active_company_context.sql`  
**Requirement:** TEN-001, TEN-002  
**Scope:** vocabulary role/status membership, satu default Company, server-side active Company context, dan audit pemilihan context.

## Yang Berubah

- Role membership dibatasi pada vocabulary approved.
- Status membership dibatasi ke `ACTIVE`/`INACTIVE`.
- Satu user hanya boleh memiliki satu default Company aktif.
- Active Company disimpan server-side dan hanya dapat diubah melalui RPC terotorisasi.
- Pemilihan context bersifat idempotent dan setiap perpindahan Company tercatat pada audit.
- Super Admin dapat memilih Company aktif mana pun; user biasa hanya Company dengan membership aktif.
- Belum ada rewrite penuh policy RLS. Selector UI sudah diintegrasikan setelah migration PASS; server context menjadi sumber utama dan `localStorage` hanya fallback/cache.

## Urutan Manual

1. Pastikan G1 fase 3 sudah PASS.
2. Jalankan `supabase/diagnostics/g1_phase4_company_context_preflight.sql`.
3. Semua 6 baris wajib `PASS` dengan `violation_rows = 0`.
4. Ambil backup/export lalu jalankan migration `20260720180000...sql` sebagai satu batch.
5. Jalankan `supabase/diagnostics/g1_phase4_company_context_postflight.sql`; harus ada 13 baris dan semuanya `PASS`.
6. Jalankan `supabase/tests/g1_phase4_company_context_tests.sql`; harus muncul notice `TEST PASSED` dan berakhir `ROLLBACK`.
7. Reload Backoffice lokal. Login, pilih Company lain, reload halaman, dan pastikan pilihan yang sama tetap aktif tanpa notice error.

## Stop Condition

- Role/status tak dikenal atau default Company ganda: jangan migration dan jangan normalisasi otomatis.
- Migration/postflight/test gagal: simpan exact output dan jangan lanjut ke policy matrix.
- Existing login/Company list rusak: hentikan rollout integration; jangan longgarkan RLS atau memberi table write langsung.

## Forward Fix

Context/audit tidak dihapus setelah dipakai. Endpoint/UI existing sudah terintegrasi; batch berikutnya memakai helper active context pada mutation policy/RPC dan menyelesaikan role/RLS matrix. Runtime tetap lokal + Supabase; Vercel belum diperlukan.

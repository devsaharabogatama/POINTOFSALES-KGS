# Runbook Penutupan G1

## Tujuan

Membuktikan seluruh tenant, role, RLS, feature entitlement, active Company,
Finance, transaksi, dan inventory boundary G1 bekerja bersama sebelum G2.

## Prasyarat

- Migration sampai `20260721150000` sudah applied.
- `g1_security_closure_preflight.sql` menghasilkan 15 `PASS`.
- POS dan Backoffice lokal tetap dapat dimuat.

## Langkah Manual

1. Jalankan `supabase/tests/g1_security_closure_tests.sql` sebagai satu batch.
2. Pastikan transaksi berakhir dengan `ROLLBACK` dan notice berikut:

```text
TEST PASSED: G1 integrated tenant, role, feature, RPC, Finance, and Inventory boundaries are closed.
```

3. Reload POS dan Backoffice lokal.
4. Pastikan Company aktif benar, menu existing utuh, dan tidak ada error pemuatan.
5. Kirim hasil test dan smoke untuk pencatatan evidence penutupan G1.

## Stop Condition

- Jangan menurunkan RLS/grant agar test lolos.
- Jangan memberikan service-role key kepada browser.
- Jangan memulai migration G2 jika integrated test atau local smoke gagal.
- Fixture test selalu rollback; bila ada fixture `G10*` tersisa, hentikan dan audit transaksi SQL Editor.

## Catatan Service Role

Pencarian lokal menemukan `SUPABASE_SERVICE_ROLE_KEY` hanya pada helper server
`backoffice/src/lib/server-auth.ts`. Pemakaiannya berada pada Route Handler
server untuk worker/provisioning, bukan komponen browser. Setiap route tetap
wajib melakukan autentikasi/otorisasi sebelum memakai admin client.

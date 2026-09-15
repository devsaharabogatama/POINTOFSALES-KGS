# Backoffice Sales — Shortage Resolution Runtime (Step 4/6.5B)

## 2026-09-15 historical-clone rehearsal evidence

Clone `idrufihckscppsyclmsu` units 57–58 installed: base preflight four PASS,
audit-fix preflight three PASS; initial/closing base postflight five PASS each,
audit postflight three PASS each. Combined rollback-only behavior 15 reported
scenarios PASS. Fixture now uses Auth-backed actor, explicit audit-fix prerequisite
and guarded Office setup cleared before operational RPC. Real root gate asserted;
runtime/installed migrations unchanged by fixture correction.
NOT_LOADED exact Transit return, linked Backorder, default date and retry verified.
LOST/DAMAGED and authenticated Warehouse-role UI smoke/UAT not proved by this test.
Stopped before unit 59 on its missing Office-mode preparation. Production/client
untouched; final fresh-clone rehearsal still pending.

Status: **LOCAL READY; MANUAL ISOLATED-DEVELOPMENT ROLLOUT PENDING**.

Target hanya isolated Development `fkywtxucmyjvpwdiqpix`. Jangan jalankan pada
production `nbxjslqojexjfogamnjt` atau staging lama `yjxpddwrjdczuqyix`.

## Scope dan impact

- Menyelesaikan line `SHORT` pending untuk `BACKORDER` atau `ACCEPT_SHORT`.
- `NOT_LOADED`/`RETURNING` memindahkan exact FIFO Transit ke Gudang asal melalui
  Stock Transfer posted. `LOST`/`DAMAGED` membuat write-off dan Finance `HOLD`.
- `BACKORDER` membuat DO/SJ child pada SO/Reservation yang sama. Tanggal boleh
  kosong (default tanggal Company) atau diedit Admin Gudang ke tanggal nonlampau.
- Original DO selesai hanya jika seluruh discrepancy selesai; SO kembali
  `PREPARING` bila Backorder ada. Qty accepted tetap invoiceable.
- Overage/Wrong Item tetap pending untuk gate physical reconstruction berikutnya.

## Urutan manual

Jalankan seluruh file, bukan selected text:

1. `supabase/diagnostics/backoffice_sales_shortage_resolution_runtime_preflight.sql`
2. Pastikan seluruh row selain `INFO` adalah `PASS`.
3. `supabase/migrations/20260912120000_backoffice_sales_shortage_resolution_runtime.sql`
   (lewati bila ledger migration ini sudah ada).
4. `supabase/diagnostics/backoffice_sales_shortage_resolution_audit_fix_preflight.sql`
5. `supabase/migrations/20260912121000_backoffice_sales_shortage_resolution_audit_fix.sql`
6. `supabase/diagnostics/backoffice_sales_shortage_resolution_audit_fix_postflight.sql`
7. `supabase/diagnostics/backoffice_sales_shortage_resolution_runtime_postflight.sql`
8. `supabase/tests/backoffice_sales_shortage_resolution_runtime_behavior.sql`
9. Jalankan kedua postflight sekali lagi.

Behavior rollback-only membuat fixture melalui call chain canonical dan menguji
default tanggal, Stock/FIFO, Reservation, parent/child DO, exact retry, serta
rollback. Stop pada SQL error, `BLOCKER`, atau `FAIL`; migration applied tidak
boleh diedit/rerun dan koreksi harus berupa forward migration.

Forward-fix `20260912121000` diperlukan karena runtime awal mencoba menulis
kolom `reason` yang tidak pernah ada pada schema canonical audit. Ia tidak
mengubah flow atau data bisnis; catatan tetap immutable pada operation
`request_payload` dan audit menyimpan before/after state canonical.

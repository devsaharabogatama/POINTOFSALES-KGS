# Backoffice Sales — Overage Commercial Approval (Step 4/6.4)

## 2026-09-15 historical-clone rehearsal evidence

Unit 55 installed on clone `idrufihckscppsyclmsu` only: preflight seven PASS,
initial/closing postflight seven PASS, rollback-only behavior PASS with nine
reported scenarios. Fixture prepares Auth-backed Super Admin and guarded Office
mode; clears setup marker and asserts root authority before operational RPCs.
SO-default price/discount, explicit override, stale version, exact/changed retry
and zero extra physical/Invoice/Finance effect verified. Runtime and migration
definitions unchanged by fixture fix. This is Super Admin RPC evidence, not
SALES_ADMIN-role authenticated UI smoke/UAT. Production/client untouched.
Stopped before unit 56 on its missing Office-mode fixture preparation.

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.

Target yang diizinkan hanya isolated Development `fkywtxucmyjvpwdiqpix`.
Jangan jalankan paket ini pada production `nbxjslqojexjfogamnjt` atau staging lama
`yjxpddwrjdczuqyix`.

## Kontrak bisnis

- Hanya discrepancy `ACCEPT_OVERAGE` berstatus `PENDING` yang diproses.
- Nilai awal menyalin baris SO: harga satuan, proporsi seluruh diskon, dan Tax
  Rule snapshot.
- Sales Admin dapat mengganti harga, total diskon overage, menonaktifkan pajak,
  atau memilih Tax Rule Sales aktif lain.
- Approval tidak mengubah SO, Qty To Invoice, Stock, FIFO, Reservation, DO,
  Invoice, Payment, Finance Event, atau Journal.
- Efek overage baru boleh terjadi pada Warehouse resolution berikutnya.
- Seluruh pending overage dalam satu discrepancy disetujui atomik, memakai
  `master_version`, operation UUID, exact retry, dan immutable audit.

## Impact map

- Direct: header/line discrepancy, operation, audit, RPC approval.
- Downstream pending: Warehouse resolution membaca commercial snapshot yang
  sudah disetujui lalu menambah accepted/invoiceable overage.
- Unchanged: clean receipt lima argumen, mixed receipt enam argumen, POS Retail,
  Stock/FIFO, Reservation, DO state, Invoice, Payment, Cashier Session, Finance.
- Compatibility: row lama memperoleh `master_version=1`; pending row tetap
  pending dan tidak dibackfill dengan fakta komersial buatan.
- Concurrency/retry: header dikunci, expected version wajib, operation UUID
  mendeteksi exact retry dan payload conflict.
- Rollback: migration forward-only. Sebelum pemakaian runtime dapat dibuat
  forward fix additive; jangan menghapus kolom/history yang telah dipakai.

## Urutan manual

Jalankan seluruh isi file, bukan selected text:

1. `supabase/diagnostics/backoffice_sales_overage_commercial_approval_preflight.sql`
2. Pastikan semua baris selain `INFO` adalah `PASS`.
3. `supabase/migrations/20260912100000_backoffice_sales_overage_commercial_approval.sql`
4. `supabase/diagnostics/backoffice_sales_overage_commercial_approval_postflight.sql`
5. `supabase/tests/backoffice_sales_overage_commercial_approval_behavior.sql`
6. Jalankan postflight sekali lagi.

Behavioral test membangun SO/DO/receipt mixed rollback-only, menguji overage
dengan default SO dan overage dengan override Sales Admin, exact retry, payload
conflict, serta zero approval effect untuk Stock/Invoice/Finance.

## Status gate

- LOCAL READY: file dan static checks selesai.
- DATABASE LIVE: user-confirmed pada isolated Development.
- SMOKE PASS: belum; UI approval belum diaktifkan pada substep ini.
- UAT PASS: belum.

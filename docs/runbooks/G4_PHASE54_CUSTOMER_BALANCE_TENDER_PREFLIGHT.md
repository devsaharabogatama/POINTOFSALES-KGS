# G4 Phase 54 — Customer Balance Tender Preflight

## Tujuan

Mengaudit kesiapan penggunaan seluruh saldo lama Customer sebagai settlement
terpisah pada Sale berikutnya sesuai POS-006. File ini SELECT-only dan belum
membuka payment method, ledger debit, UI, atau mutation baru.

## Jalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g4_phase54_customer_balance_tender_preflight.sql`

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER`: data/dependency tidak aman; jangan lanjut foundation;
- `REVIEW`: histori tender lama perlu keputusan/backfill eksplisit;
- `SETUP`: gap runtime/schema yang memang akan dibuat pada phase foundation;
- `PASS`: invariant live aman;
- `INFO`: inventory/boundary, bukan kegagalan.

Expected baseline sebelum foundation adalah runtime, ledger source, dan payment
snapshot berstatus `SETUP`. Browser direct write wajib seluruhnya `false`.

## Contract yang dilindungi

- hanya Customer reguler pada Company yang sama;
- lifecycle `ACTIVE` atau `WIND_DOWN` boleh menghabiskan saldo lama;
- seluruh saldo lama wajib digunakan—tidak boleh parsial;
- bila saldo lebih besar daripada grand total, checkout diblokir dan POS meminta
  tambahan minimum belanja;
- settlement tidak mengubah harga, diskon, tax, rounding, atau revenue;
- debit ledger/cache/Sale/Payment/Event terjadi atomic dan idempotent;
- Offline Customer Balance tetap tertutup;
- direct table mutation browser tetap dilarang.

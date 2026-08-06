# G4 Phase 25 — Sales Return Readiness Preflight

**Status:** READY FOR MANUAL PREFLIGHT

Phase ini hanya mengaudit kesiapan source transaksi untuk Sales Return. Belum
ada migration, mutation Return, refund, stock restoration, approval, atau UI.

## 1. Jalankan Preflight

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g4_phase25_sales_return_readiness_preflight.sql`

Kirim seluruh output `check_name,status,details`.

## 2. Expected Result

- `g4_phase25_dependencies=PASS`;
- seluruh check source Sale/line/Payment/FIFO/Bundle dan Offline berstatus
  `PASS`;
- `sales_return_finance_catalog=PASS`;
- `posted_sale_company_return_category_readiness=PASS`;
- `canonical_sales_return_schema_state=SETUP` dan
  `canonical_sales_return_routine_state=SETUP` adalah expected gap sebelum
  foundation Phase berikutnya;
- warehouse readiness boleh `REVIEW`; hasilnya menentukan apakah Gudang
  `DAMAGED` perlu diprovision sebelum Return fisik dibuka;
- check `INFO` hanya inventory/boundary dan bukan kegagalan.

`BLOCKER` selain expected `SETUP` menghentikan implementasi. Jangan memperbaiki
data historis secara manual.

## 3. Kontrak yang Diaudit

- hanya Sale `POSTED` yang dapat menjadi source Return;
- refundable quantity kelak dihitung kumulatif per source line dan tidak boleh
  melebihi quantity Sale;
- harga, discount, Tax, rounding, Payment, receipt, UOM, Bundle allocation,
  serta FIFO cost memakai snapshot transaksi asal;
- `SALEABLE` mengembalikan stock ke Gudang STORE;
- `DAMAGED` mengembalikan stock ke Gudang DAMAGED;
- `NO_PHYSICAL_RETURN` tidak membuat stock-in atau membalik HPP;
- full refund membalik total final/rounding asal, sedangkan partial refund
  memakai snapshot line dan rounding refund tersendiri;
- refund Cash/Transfer/Customer Balance tetap event terpisah dan mengikuti
  entitlement;
- Sale Offline wajib sudah sync dan final `POSTED` sebelum dapat diretur;
- Return final wajib transactional, idempotent, concurrency-safe, audited,
  dan tidak membuka direct browser write.

## 4. Boundary

Preflight ini tidak membuka Finance journal/GL, Customer Balance, TEMPO,
Expense, Deposit, Debit/Credit Note, Purchase Return, atau G5 Purchasing.
Financial Event Return kelak tetap `HOLD` sampai G6 Finance Posting.


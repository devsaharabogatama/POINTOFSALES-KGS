# PRD-1 Pre-Deploy Closing Preflight

**Status:** READY TO RUN  
**Scope:** diagnostic konsolidasi sebelum Vercel Preview; diperbarui setelah
G6 Phase 8H historical Finance closure PASS

## Tujuan

Menentukan gap aktual untuk closing regression tanpa mengubah schema/data.
Diagnostic sekarang juga mengaudit 24 permission `ENFORCED` dan regular
multi-Company identity dengan override berbeda per Company.
Diagnostic mengaudit migration chain, role coverage, dua Company, Store/POS/
Gudang, master minimum, job nonterminal, Stock–Movement–FIFO, Finance queue/
journal, Invoice/Surat Jalan/Return, browser write boundary, dan scope branding.

## Jalankan

Jalankan seluruh file berikut sebagai satu query:

`supabase/diagnostics/prd_phase1_predeploy_closing_preflight.sql`

Kirim seluruh output, termasuk `SETUP`, `DEFERRED`, dan `INFO`.

## Interpretasi

- `BLOCKER`: harus diperbaiki sebelum membuat fixture atau membuka Preview.
- `SETUP`: data UAT belum lengkap; expected bila Company kedua/role belum dibuat.
- `PASS`: invariant live aman pada saat query dijalankan.
- `DEFERRED`: boundary roadmap lain yang sengaja tidak dibuka. Historical
  Finance HOLD bukan lagi deferred setelah Phase 8H (`HOLD=0`).
- `INFO`: inventory atau pemeriksaan eksternal/manual.

## Setelah Output Bersih

1. lengkapi fixture minimal sesuai `ACP7_AUTHENTICATED_CLOSURE_MATRIX.md`;
   jangan membuat ulang Company yang sudah tersedia;
2. pastikan akun Owner, Admin, Finance, Accounting, Warehouse
   Admin, Store Manager, dan Cashier—jangan berbagi password produksi;
3. isi minimal Store, Terminal, sale-source Warehouse, Product/UOM, Customer,
   Payment Method, stock/FIFO, dan branding no-logo/logo;
4. jalankan matrix Home/Fast Link/direct route/API/RPC per role;
5. jalankan switch Company dan pastikan state/list/detail/export/import/Stock/
   Sale/Finance/document Company lama hilang serta akses ID lintas tenant ditolak;
6. jalankan E2E Pickup, Delivery+ongkir, Offline, Return barang-only dan full
   Return+ongkir, Invoice/SJ/reprint, Expense, Deposit, Purchase Receipt/Invoice/
   Payment, Data Exchange, dan Finance report;
7. ulangi stock/FIFO/payment/event/journal reconciliation;
8. baru audit env dan membuka Vercel Preview—bukan Production.

Tidak ada akun, password, Company, entitlement, atau data bisnis yang dibuat
oleh preflight ini.

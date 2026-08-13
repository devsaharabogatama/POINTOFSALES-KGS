# G6 Corrective Phase 6 — Reporting and Reconciliation Preflight

## Tujuan

Mengaudit ledger, cut-off, report model, pending analysis, serta perbandingan
Stock FIFO, Supplier AP, dan Customer Balance terhadap GL sebelum report RPC,
cache, export, atau UI dibuat.

## Boundary

- hanya canonical journal `POSTED` boleh masuk angka laporan keuangan;
- event `HOLD`/failed dan queue non-final hanya masuk operational pending;
- cut-off memakai `accounting_date` dan timezone active Company;
- prior-period adjustment harus terlihat terpisah;
- reconciliation hanya menampilkan difference dan tidak membuat adjustment;
- report/RPC wajib tenant- dan role-scoped;
- 25 event unsupported tetap deferred;
- diagnostic tidak memproses satu historical `STOCK_OPENING` live.

## Cara menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g6_phase6_reporting_reconciliation_preflight.sql`

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER`: integrity/security rusak; hentikan Phase 6.
- `REVIEW`: live-state membutuhkan keputusan sebelum DDL.
- `BACKFILL`: exposure/subledger belum mempunyai journal final; expected selama
  historical posting belum disetujui.
- `SETUP`: schema/RPC/report fixture belum ada; expected baseline.
- `DEFERRED`: contract posting source belum didukung.
- `PASS`/`INFO`: invariant aman atau inventory saja.

Expected baseline dapat mencakup:

- report/reconciliation schema dan enam RPC `SETUP`;
- report fixture `SETUP` bila satu historical `STOCK_OPENING` belum diproses;
- Stock/AP/Customer Balance versus GL `BACKFILL` bila source event masih HOLD;
- 25 unsupported event `DEFERRED`.

`BLOCKER` wajib nol. Jangan menghilangkan difference dengan journal tebakan.

## Rollback

Tidak ada. File ini satu statement `SELECT` dan tidak mengubah data/schema.

## Next safe step

Setelah live output direview, Phase 6 dibagi secara sempit:

1. POSTED-only Trial Balance/GL + report metadata/version/export foundation;
2. P&L/Neraca setelah grouping versioned tersedia;
3. reconciliation read model setelah fixture Stock/AP/Customer Balance jelas;
4. operational pending report terpisah dari angka financial.

Report UI tetap tertutup sampai RPC, fixture, tenant-negative, timezone, dan
reconciliation behavior lulus.

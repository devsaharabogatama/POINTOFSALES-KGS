# Backoffice Sales Discrepancy Contract — Step 4/6.1

> Setelah foundation ini applied, lanjutkan forward correction Step 4/6.2 di
> [`BACKOFFICE_SALES_DISCREPANCY_PHYSICAL_STATE_ROLLOUT.md`](BACKOFFICE_SALES_DISCREPANCY_PHYSICAL_STATE_ROLLOUT.md).
> Migration `20260911164000` tidak boleh diedit atau dijalankan ulang.

Status: `LOCAL READY; MANUAL ISOLATED-DEVELOPMENT SQL GATE PENDING`  
Target tunggal: Supabase Development `fkywtxucmyjvpwdiqpix`.

## Outcome

Paket ini membangun kontrak additive untuk penerimaan Customer campuran per
baris DO. Quantity yang diterima dapat dipisahkan dari quantity bermasalah.
Quantity diterima akan menjadi dasar `Qty To Invoice` pada runtime berikutnya,
tanpa menunggu Backorder/discrepancy selesai.

Disposition yang dikunci:

- kurang: `BACKORDER` atau `ACCEPT_SHORT`;
- lebih: `ACCEPT_OVERAGE` atau `RETURN_OVERAGE`;
- salah barang: `REPLACE_WRONG_ITEM` dengan Product aktual wajib tercatat;
- hilang/rusak: `WRITE_OFF_LOST` atau `WRITE_OFF_DAMAGED`;
- `ACCEPT_OVERAGE` wajib approval Sales Admin;
- Backorder, return overage, replacement, lost, dan damaged wajib penyelesaian
  Admin Gudang;
- penyelesaian lost/damaged akan diteruskan ke Finance queue pada gate runtime,
  bukan membuat jurnal pada migration foundation ini.

Dokumen Backorder kelak memakai nomor SJ baru, menunjuk SO dan parent SJ awal.
SJ awal yang telah final tidak ditulis ulang; activity log hanya menambahkan
link ke SJ Backorder.

## Impact map

Direct impact:

- empat relation baru untuk case, line, exact operation, dan immutable audit;
- dua private validator untuk pasangan discrepancy/action dan payload campuran;
- RLS aktif dan zero browser table/private-routine privilege.

Downstream yang sengaja belum diaktifkan:

- mutation penerimaan Customer campuran;
- sale-out FIFO parsial dan update Qty To Invoice;
- approval Sales Admin, resolution Admin Gudang, Return-to-Warehouse;
- pembuatan DO/SJ Backorder;
- Finance queue lost/damaged;
- UI form penerimaan dan activity log.

Compatibility:

- RPC clean receipt lima argumen tetap ada dan tidak diganti;
- data receipt/DO/SO/Invoice/Stock/FIFO/Finance existing tidak dibackfill;
- POS Retail, Cashier Session, Offline, Purchasing, dan production tidak berubah.

## Urutan manual

Jalankan satu file penuh per langkah melalui SQL Editor project Development:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_discrepancy_contract_preflight.sql)
2. Pastikan tidak ada `BLOCKER` atau SQL error.
3. [Migration](../../supabase/migrations/20260911164000_backoffice_sales_discrepancy_contract_foundation.sql)
4. [Postflight](../../supabase/diagnostics/backoffice_sales_discrepancy_contract_postflight.sql)
5. Pastikan seluruh baris selain `INFO` berstatus `PASS`.
6. [Behavioral test](../../supabase/tests/backoffice_sales_discrepancy_contract_behavior.sql)
7. Jalankan postflight sekali lagi.

Preflight aman dijalankan ulang sesudah migration. Ia mengharapkan nol object
sebelum ledger `20260911164000` ada, dan tepat empat relation/tiga routine setelah
ledger ada. Object parsial atau jumlah yang berbeda tetap menjadi `BLOCKER`.

Jangan memakai `supabase db push`, jangan menjalankan paket ini pada production
atau staging lama, dan berhenti pada error/`BLOCKER`/`FAIL`.

## Expected behavioral evidence

- contoh 10 dikirim: 8 diterima dan 2 Backorder tervalidasi sebagai dua bucket;
- 8 diterima adalah authority Qty To Invoice pada runtime berikutnya;
- Accept Overage memerlukan Sales approval;
- Wrong Item tanpa Product aktual ditolak;
- kombinasi discrepancy/action yang tidak sah ditolak;
- behavioral tidak bergantung pada Company/order fixture dan seluruhnya rollback.

## Forward-fix / rollback

Sebelum ada data discrepancy, foundation dapat dilepas dengan urutan dependency
terbalik. Setelah data ada, jangan drop relation atau menghapus histori; gunakan
forward-fix additive. Runtime berikutnya wajib mengunci SO/DO/Transit/FIFO dan
operation identity dalam satu transaksi serta tetap mempertahankan wrapper clean
receipt untuk compatibility.

## Next safe step

Hanya setelah migration, behavior, dan postflight dikonfirmasi PASS: bangun Step
4/6.2, yaitu runtime Customer confirmation campuran dan sale-out hanya untuk qty
accepted. Belum boleh membuka approval/resolution UI sebelum runtime tersebut
lulus exact retry, stale version, cross-tenant, dan stock/FIFO reconciliation.

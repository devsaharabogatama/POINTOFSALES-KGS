# Backoffice Purchase Return End-to-End Rollout

**Status paket:** DATABASE LIVE through `20260919143000`; focused negative-stock behavior/postflight PASS.
**Target:** Production Supabase + Backoffice client.  
**Prinsip:** berhenti pada error/`BLOCKER`/`FAIL` pertama; jangan melompati file,
mengubah ledger manual, atau menjalankan migration yang sudah berhasil dua kali.

## Urutan SQL Editor

1. Jalankan seluruh file
   `supabase/diagnostics/backoffice_purchase_return_e2e_preflight.sql`.
2. Pastikan tidak ada `BLOCKER`.
3. Jalankan migration berikut tepat satu kali dan berurutan:
   - `20260919140000_backoffice_purchase_return_draft_runtime.sql`;
   - `20260919141000_backoffice_purchase_return_finance_runtime.sql`;
   - `20260919142000_backoffice_purchase_return_po_cancellation_gate.sql`.
4. Jalankan seluruh file
   `supabase/tests/backoffice_purchase_return_e2e_behavior.sql`.
   Hasil wajib satu baris `PASS`; seluruh fixture otomatis `ROLLBACK`.
5. Jalankan seluruh file
   `supabase/diagnostics/backoffice_purchase_return_e2e_postflight.sql`.
   Semua contract/reconciliation wajib `PASS`; baris inventory boleh `INFO`.
6. Baru deploy client Backoffice dari commit yang memuat migration tersebut.

## Authenticated Smoke

Gunakan PO uji yang benar-benar mempunyai Posted Goods Receipt. FIFO sumber
boleh masih tersedia atau sudah habis karena menutup stok minus.

1. Buka detail PO, klik `Retur ke Supplier`.
2. Pastikan Goods Receipt, Gudang, barang, kondisi, sisa quantity Receipt yang
   belum diretur, UOM, dan Qty tampil. Qty tidak boleh melewati quantity sumber
   yang belum diretur; FIFO sumber nol bukan blocker setelah forward fix.
3. Simpan Draft, muat ulang, edit Draft, lalu pastikan versi terbaru tersimpan.
4. Approve dan Post. Pastikan:
   - stok dan exact source FIFO berkurang satu kali;
   - Stock Movement `PURCHASE_RETURN` terbentuk;
   - bagian belum ditagih dikurangi lebih dulu;
   - bagian yang sudah ditagih membentuk Supplier Credit;
   - bagian Bill yang sudah dibayar menjadi Piutang Refund Supplier;
   - jurnal Posted seimbang;
   - retry tombol tidak menggandakan effect.
5. Buka Pembayaran Supplier. Saldo Bill wajib sudah dikurangi Supplier Credit;
   pembayaran melebihi saldo net wajib ditolak, termasuk Draft pembayaran yang
   dibuat sebelum Supplier Credit tetapi baru divalidasi sesudahnya.
6. Coba batalkan PO sebelum seluruh penerimaan diretur: harus diblok dengan
   alasan jelas. Setelah net receipt nol dan Draft dependency selesai, PO boleh
   dibatalkan.
7. Uji satu Draft Retur melalui POS/PWA existing untuk memastikan aturan
   Cashier Session dan flow Retail tidak berubah.

## Multi-Receipt

Satu Return document sengaja hanya mengikat satu Goods Receipt dan satu Gudang
agar source FIFO tidak tercampur. Untuk PO dengan beberapa Receipt/Gudang,
buat satu Draft per pasangan Receipt/Gudang dari source picker sampai seluruh
qty yang memang dikembalikan selesai. Sistem menghitung net receipt PO dari
semua dokumen posted tersebut.

## Forward-Fix / Rollback

- Ketiga migration menggunakan satu transaksi per file. Error sebelum `COMMIT`
  otomatis membatalkan seluruh perubahan file itu.
- Setelah transaksi bisnis Backoffice Return diposting, jangan drop object dan
  jangan menghapus histori. Perbaikan wajib additive/forward-fix dengan dokumen
  koreksi source-linked.
- Sebelum ada Backoffice Return posted, emergency rollback hanya boleh dilakukan
  dalam maintenance window dengan mengembalikan wrapper Supplier Payment/PO,
  menghapus object additive dalam urutan dependency terbalik, dan menghapus
  ledger tiga migration tersebut dalam transaksi yang dijaga. Jangan memakai
  prosedur ini setelah data bisnis baru terbentuk.
- Piutang Refund Supplier tidak otomatis dianggap kas diterima. Settlement
  transfer/offset berikutnya tetap merupakan langkah Finance terpisah dan tidak
  boleh memutasi Supplier Payment lama.

## Status yang Harus Dicatat

- `LOCAL READY`: lint/build/static SQL selesai.
- `DATABASE LIVE`: ketiga migration committed.
- `CLIENT DEPLOYED`: build client baru aktif.
- `SMOKE PASS`: checklist authenticated di atas lulus.
- `UAT PASS`: user bisnis menyetujui hasil transaksi dan laporan.

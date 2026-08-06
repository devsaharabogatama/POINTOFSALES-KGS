# G5 Phase 9 — Purchase Return Operational UI

## Status

`READY FOR AUTHENTICATED SMOKE TEST` — database Phase 8 telah dikonfirmasi user
seluruhnya PASS. PWA dan Backoffice lint/build lulus pada 2026-08-06.

Forward-fix UOM `20260806080000` menunggu rollout manual: Retur boleh memilih
UOM Produk aktif berbeda dari UOM Receipt, misalnya Receipt satu Dus diretur
beberapa Ketul.

## Flow yang dibuka

1. Kasir dengan Session OPEN memilih `Retur Supplier` di POS.
2. Kasir memilih Goods Receipt POSTED dan Gudang sumber yang masih mempunyai FIFO penerimaan asal.
3. Kasir memilih barang, UOM, quantity, tanggal, dan alasan lalu mengirim Draft.
4. Store Manager/Company Admin membuka `Purchase > Retur Pembelian`.
5. Manager memilih `Setujui` tanpa alasan, atau `Tolak` dengan alasan wajib.
6. Dokumen APPROVED diposting terpisah. Hanya saat Post stok/FIFO berkurang,
   Movement `PURCHASE_RETURN` dan AP adjustment tercatat.

Finance Event tetap `HOLD`; Supplier Invoice, matching, payment, Debit Note
final, dan jurnal G6 tidak dibuka oleh fase ini.

## Smoke test wajib

1. Catat Stock Real Product–Gudang dan nilai batch sebelum retur.
2. Dari POS Session OPEN, buat draft sebagian dari kondisi `Baik` atau `Rusak`.
   Untuk Product multi-UOM, pilih UOM lebih kecil dari Receipt dan pastikan hasil
   base quantity sesuai faktor konversinya.
3. Pastikan setelah Draft stok belum berubah.
4. Di Backoffice, buka detail dan cocokkan Supplier, Receipt, Gudang, UOM,
   kondisi, quantity, serta nilai provisional.
5. Klik `Setujui`; alasan tidak diminta dan stok belum berubah.
6. Klik `Post Retur`; dokumen POSTED dan stok berkurang tepat satu kali.
7. Periksa Kartu Stok: Movement `PURCHASE_RETURN`, base UOM, source, dan balance after lengkap.
8. Muat ulang dan pastikan Post ulang tidak tersedia.
9. Uji Draft lain lalu `Tolak`; alasan wajib dan stok tidak berubah.
10. Tekan Escape pada modal detail/konfirmasi dan pastikan modal tertutup.

Jika daftar kosong, pastikan Goods Receipt sudah POSTED, stok batch asal masih
tersisa, Product-UOM pembelian aktif, dan receipt berasal dari Store sesi aktif.

## Evidence lokal

- `pwa`: lint PASS; production build PASS.
- `backoffice`: lint PASS; production build PASS.
- Next route list, review, post, dan cancel Purchase Return terdeteksi.

## Compatibility

- tidak ada migration/schema baru;
- tidak ada direct browser write ke tabel final;
- RPC Phase 8 tetap satu-satunya mutation authority;
- Goods Receipt, Supplier Order, POS Sale, dan Finance HOLD tidak diubah.

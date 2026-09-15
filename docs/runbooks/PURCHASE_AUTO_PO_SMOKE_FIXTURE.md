# Purchase AUTO_PO Smoke Fixture

Fixture ini hanya untuk isolated Development `fkywtxucmyjvpwdiqpix`.
Production dan staging tidak boleh menjalankannya.

Fixture memakai kondisi Development yang telah diaudit pada 2026-09-14:

- Company `KGS Company`;
- actor `localadmin@local.com`;
- stok `Backoffice UI Test Product` sebesar `-102` pada Gudang sumber;
- Gudang penerimaan default `TERIMA`;
- mode awal Company `AUTO_RO`;
- tidak ada PO terbuka atau batch hari ini.

Script menambah tiga Product dummy dan empat Supplier dummy, menghubungkan
setiap Product ke Supplier berbeda, lalu menjalankan scheduler canonical dengan
waktu efektif hari ini pukul `23:59:30` Asia/Jakarta. Hasil wajib tepat empat PO
confirmed. Mode Company dikembalikan ke `AUTO_RO` setelah generator selesai.
PO tidak membuat Receipt, Stock Movement, AP, Bill, Payment, atau Journal.

## Urutan

1. Jalankan `supabase/diagnostics/purchase_auto_po_smoke_fixture_preflight.sql`.
2. Hanya jika seluruh baris PASS, jalankan
   `supabase/operations/seed_purchase_auto_po_smoke_fixture.sql`.
3. Jalankan
   `supabase/diagnostics/purchase_auto_po_smoke_fixture_postflight.sql`.
4. Muat ulang Backoffice lokal dan buka Purchase > Purchase Order.

## Alur smoke per PO

1. Buka detail PO dan cocokkan Supplier, quantity, harga, serta Gudang `TERIMA`.
2. Buat dan Post penerimaan dari Gudang.
3. Pastikan status penerimaan selesai dan Status Bill menjadi `Siap dibuat`.
4. Klik Status Bill, buat Faktur Supplier, lalu Validate/Post sesuai runtime lama.
5. Lanjutkan Pembayaran Supplier dan Antrian Jurnal sesuai akses Finance.

Fixture sengaja persistent agar dapat diuji end-to-end. Jangan menghapus row PO,
Receipt, Bill, Payment, Stock Movement, Financial Event, atau Journal. Setelah
UAT selesai, Product/Supplier fixture dapat dinonaktifkan; histori transaksi
tetap dipertahankan.

## Hasil eksekusi 2026-09-14

- Preflight: seluruh check `PASS`.
- Batch scheduler: `POB-20260914-0000000006`.
- PO: `PO-20260914-0000000009`, `PO-20260914-0000000010`,
  `PO-20260914-0000000011`, dan `PO-20260914-0000000012`.
- Semua PO berstatus `CONFIRMED`, masing-masing mempunyai Supplier berbeda.
- Setting Company telah kembali ke `AUTO_RO`.
- Postflight awal: seluruh contract check `PASS`; belum ada Goods Receipt.

Postflight `fixture_downstream_initial_state` hanya untuk kondisi sebelum smoke.
Setelah salah satu PO diterima, check tersebut memang tidak lagi diharapkan PASS.

# Cutover Product-UOM Company ke PACK Saja

Runbook ini dipakai ketika satu Company tidak lagi memakai DUS untuk pembelian
atau penjualan dan seluruh transaksi baru harus memakai PACK.

## Batas operasi

- Hanya Company dengan `company_code` yang ditulis di konfigurasi SQL.
- PACK diaktifkan untuk pembelian dan penjualan.
- DUS dinonaktifkan untuk transaksi baru, bukan dihapus dari histori.
- Relasi Supplier aktif yang masih memakai DUS dipindahkan ke PACK; harga per
  DUS dikonversi proporsional menjadi harga per PACK.
- Rule Pricelist DUS aktif dinonaktifkan. Rule PACK tidak diubah.
- Jika DUS menjadi referensi berat, berat dikonversi menjadi berat per PACK.
- Sale, Purchase, Stock, FIFO, Invoice, dan jurnal lama tidak diubah.

## Menjalankan

1. Buka `supabase/operations/convert_company_products_to_pack_only.sql`.
2. Isi `target_company_code` dengan kode Company atau UUID Company yang tepat.
   Contoh untuk Khadijah Muda Sejahtera: `KMS` atau
   `4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8`.
3. Biarkan `execute_change = FALSE`, lalu jalankan seluruh file.
4. Jangan lanjut apabila ada hasil `BLOCKER`.
5. Jika seluruh blocker `PASS`, ubah:
   - `execute_change = TRUE`;
   - `confirmation = 'ACTIVATE_PACK_DISABLE_DUS'`.
6. Jalankan seluruh file sekali lagi.
7. Hasil akhir wajib `operation_mode = APPLIED`,
   `remainingActiveDusRows = 0`, dan `historyDeleted = false`.
8. Kembalikan `execute_change = FALSE` agar file tidak sengaja dijalankan ulang
   dalam mode APPLY.

## Setelah cutover

Lakukan refresh keras pada Backoffice/POS. Untuk terminal Offline, lakukan sync
dan muat ulang katalog ketika online sebelum memulai transaksi baru.

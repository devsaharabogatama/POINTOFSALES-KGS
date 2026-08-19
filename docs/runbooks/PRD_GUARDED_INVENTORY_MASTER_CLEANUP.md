# Guarded UOM dan Product Category Cleanup

## Outcome

Perubahan ini menutup kebutuhan koreksi salah import sebelum UAT:

- nama UOM kembali terlihat pada tabel Master Data;
- UOM dan Product Category dapat diedit;
- UOM/Category yang belum direferensikan dapat dihapus permanen;
- master yang sudah direferensikan Product, UOM conversion, transaksi, atau
  konfigurasi lain tidak dapat dihapus dan harus dinonaktifkan;
- nama/status UOM yang sudah dipakai masih dapat diperbaiki, tetapi tipe,
  kebijakan desimal, dan precision dikunci agar quantity historis tidak berubah.

## File rollout

1. Migration:
   `supabase/migrations/20260818090000_prd_guarded_inventory_master_cleanup.sql`
2. Postflight:
   `supabase/diagnostics/prd_guarded_inventory_master_cleanup_postflight.sql`
3. Behavioral test (selalu rollback):
   `supabase/tests/prd_guarded_inventory_master_cleanup_tests.sql`

## Urutan manual

1. Jalankan migration pada staging Supabase SQL Editor.
2. Jalankan seluruh postflight; setiap check selain inventory `INFO` harus
   `PASS`.
3. Jalankan behavioral test; harus berakhir dengan notice `TEST PASSED` dan
   transaksi `ROLLBACK`.
4. Jalankan ulang postflight.
5. Deploy/restart Backoffice, buka Master Data, lalu smoke:
   - Nama UOM terlihat;
   - edit nama UOM berhasil;
   - UOM/Category kosong dapat dihapus dari modal konfirmasi;
   - UOM/Category yang dipakai menampilkan penolakan dan tetap ada;
   - user tanpa `inventory.master_data MANAGE` tidak melihat aksi perubahan.

## Compatibility dan rollback

Public save RPC lama tidak diubah. Product, import, stok, transaksi, dan audit
historis tetap menggunakan ID/snapshot yang sama. Delete baru hanya untuk row
tanpa referensi dan tetap diaudit.

Rollback aman adalah forward-fix: cabut EXECUTE kedua delete RPC dan sembunyikan
tombol delete. Jangan menghapus audit `DELETE` yang sudah terbentuk. Trigger
semantic UOM boleh dicabut hanya jika ada migration konversi UOM historis yang
terpisah dan disetujui.


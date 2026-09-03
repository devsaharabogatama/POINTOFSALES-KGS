# Forward-fix Serah Barang Surat Jalan Pickup

## Tujuan

Memulihkan lifecycle Pickup yang disetujui tanpa mengubah alur Delivery atau
stock effect ODR:

- Pickup legacy tanpa Reservation: `READY -> DELIVERED`, tanpa Dispatch,
  Movement, FIFO, atau Finance effect;
- Pickup ODR dengan Reservation: wajib **Keluarkan barang** dahulu, kemudian
  **Sudah diserahkan**;
- Delivery tetap wajib Dispatch sebelum diterima.

## Urutan eksekusi Supabase

1. Jalankan
   `supabase/diagnostics/inventory_pickup_handover_lifecycle_preflight.sql`.
2. Hentikan bila ada `BLOCKER`.
3. Jalankan
   `supabase/migrations/20260903130000_inventory_pickup_handover_lifecycle_fix.sql`.
4. Jalankan
   `supabase/tests/inventory_pickup_handover_lifecycle_behavior.sql`.
5. Jalankan
   `supabase/diagnostics/inventory_pickup_handover_lifecycle_postflight.sql`.
6. Hentikan bila ada SQL error atau `FAIL`.
7. Hard refresh Backoffice. Buka satu Surat Jalan **Ambil di toko** berstatus
   **Siap disiapkan**, pilih **Sudah diserahkan**, lalu pastikan status menjadi
   **Sudah diserahkan**.

## Pemeriksaan dampak

Untuk Pickup legacy, tindakan serah tidak boleh menambah Stock Movement,
alokasi Dispatch, Financial Event, atau jurnal. Untuk Pickup ODR, UI tetap
menawarkan **Keluarkan barang** sebelum serah sehingga Reservation dan stok
diproses oleh runtime canonical.

## Forward-fix / rollback

Perubahan hanya mengganti satu check constraint dan tidak melakukan backfill.
Jika postflight gagal, jangan memakai tombol serah Pickup. Pertahankan data dan
lakukan forward-fix; jangan menghapus dokumen atau mengubah status langsung.

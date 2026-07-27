# G2 Phase 13 — Reusable Customer Pricelist Preflight

## Tujuan

Mengaudit data live sebelum mengubah model dari satu header Pricelist untuk satu
Customer menjadi satu Pricelist reusable yang dapat dipilih oleh banyak
Customer.

Target ownership terbaru:

- menu Pricelist mengelola nama, cakupan Store, periode, prioritas, dan harga;
- menu Customer memilih Pricelist khusus Customer;
- satu Pricelist khusus boleh dipakai banyak Customer;
- satu Customer reguler hanya mempunyai maksimal satu Pricelist khusus pilihan;
- Walk-In selalu memakai Global default dan tidak boleh diberi Pricelist khusus.

## Cara menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh isi
   `supabase/diagnostics/g2_phase13_pricelist_customer_assignment_preflight.sql`.
3. Kirim seluruh hasil `check_name,status,details`.

File ini `SELECT-only` dan tidak mengubah Pricelist, Customer, Sales, atau
checkout.

## Interpretasi

- `BLOCKER`: ada dependency atau referensi Customer legacy yang tidak aman.
- `REVIEW`: ada Pricelist Customer aktif tanpa default legacy; perlu dipastikan
  apakah sengaja hanya alternatif atau harus dipilih saat backfill.
- `BACKFILL`: expected bila relasi lama perlu dipindahkan ke Customer.
- `PASS`: invariant yang diaudit bersih.
- `INFO`: inventory saja.

## Rencana forward-fix setelah hasil disetujui

Migration berikutnya akan:

1. menambah `customers.default_pricelist_id` tenant-safe;
2. memindahkan default assignment legacy ke Customer;
3. membuat header Pricelist `CUSTOMER` reusable tanpa `customer_id` wajib;
4. memperbarui guarded RPC dan audit;
5. memindahkan dropdown assignment ke modal Customer;
6. menghapus pilihan Customer dari form Pricelist;
7. mempertahankan checkout/resolver dalam keadaan belum aktif.

Migration applied lama tidak akan diedit. Rollback operasional menggunakan
forward-fix karena perubahan assignment dapat dibuat setelah ada data baru.

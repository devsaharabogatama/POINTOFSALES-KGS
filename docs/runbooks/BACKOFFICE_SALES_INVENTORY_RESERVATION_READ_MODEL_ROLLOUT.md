# Backoffice Sales Inventory Reservation Read Model Rollout

Scope gate ini hanya menggabungkan sisa Reserved Out POS dan Backoffice pada
RPC Stock Real canonical serta menampilkan lineage alokasinya. Gate tidak
memindahkan barang, tidak mengubah On Hand/FIFO, dan belum mengaktifkan operasi
Delivery Order.

Status saat ini: migration sudah dry-run dan applied hanya ke isolated
Development `fkywtxucmyjvpwdiqpix`; manual postflight, behavioral, authenticated
client smoke, dan UAT masih pending. Production/staging tidak disentuh.

## Urutan aman

1. Pastikan aplikasi development menunjuk project isolated
   `fkywtxucmyjvpwdiqpix`, bukan production/staging lama.
2. Jalankan `supabase/diagnostics/backoffice_sales_inventory_reservation_read_model_preflight.sql`.
   Stop jika ada `BLOCKER`.
3. Terapkan migration
   `supabase/migrations/20260909148000_backoffice_sales_inventory_reservation_read_model.sql`.
4. Jalankan
   `supabase/diagnostics/backoffice_sales_inventory_reservation_read_model_postflight.sql`.
   Stop jika ada `FAIL`.
5. Jalankan
   `supabase/tests/backoffice_sales_inventory_reservation_read_model_behavior.sql`.
   Script harus selesai dan mengembalikan PASS; seluruh fixture di-rollback.
6. Jalankan lint/build Backoffice, login memakai user development, buka
   Inventory > Stock Real, lalu cocokkan satu SO Backoffice terkonfirmasi:
   Reserved bertambah, Available berkurang, On Hand/Nilai FIFO tidak berubah,
   dan detail menampilkan SO, Customer, DO, tanggal rencana, serta quantity.

## Compatibility dan forward-fix

- Response lama `balances` dan `warehouses` dipertahankan; field baru bersifat
  additive. Client menerima versi read model 1 maupun 2 selama rollout lokal.
- POS availability RPC tidak diubah. Stock Overview hanya membaca dua sumber
  reservation dan tidak menulis tabel bisnis.
- Jika migration gagal sebelum COMMIT, transaksi rollback otomatis.
- Setelah migration committed, jangan menghapus migration ledger atau function
  manual. Buat forward-fix yang mengembalikan definisi Stock Overview dari
  `20260829090000` bila read model harus dinonaktifkan.
- Production tidak boleh disentuh tanpa instruksi deployment eksplisit dan
  compatibility preflight terpisah.

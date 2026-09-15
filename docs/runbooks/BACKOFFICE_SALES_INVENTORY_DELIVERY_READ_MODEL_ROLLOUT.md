# Backoffice Sales Inventory Delivery Read Model Rollout

Gate ini membuat Delivery Order Backoffice hasil Confirm terlihat pada modul
Inventory > Surat Jalan. List dan detail menampilkan SO, Customer, Gudang,
jadwal, jenis INITIAL/BACKORDER, status, quantity planned/shipped/received, dan
sisa quantity.

Operasi Dispatch, penerimaan Customer, bulk status, print audit, discrepancy,
dan Backorder sengaja tetap terkunci. Kontrak movement Gudang -> Transit serta
disposition discrepancy diselesaikan pada gate mutation berikutnya.

Status 2026-09-09: migration sudah live hanya pada isolated Development
`fkywtxucmyjvpwdiqpix`; lint dan full build PASS. Langkah 4-6 masih menunggu
eksekusi/verifikasi manual user. Production/staging tidak disentuh.

## Urutan Development

1. Pastikan project-ref `fkywtxucmyjvpwdiqpix`.
2. Jalankan
   `supabase/diagnostics/backoffice_sales_inventory_delivery_read_model_preflight.sql`.
   Stop bila ada `BLOCKER`.
3. Apply migration
   `supabase/migrations/20260909149000_backoffice_sales_inventory_delivery_read_model.sql`.
4. Jalankan
   `supabase/diagnostics/backoffice_sales_inventory_delivery_read_model_postflight.sql`.
   Stop bila ada `FAIL`.
5. Jalankan
   `supabase/tests/backoffice_sales_inventory_delivery_read_model_behavior.sql`.
   Script harus selesai dengan PASS dan seluruh fixture di-rollback.
6. Restart/refresh Backoffice lokal. Buka Inventory > Surat Jalan. DO dari SO
   Backoffice harus terlihat dan Detail harus menampilkan line yang benar.
   Checkbox bulk dan tombol mutation/print untuk sumber Backoffice harus tetap
   tidak tersedia pada gate ini.

## Compatibility dan forward-fix

- RPC/UI POS Surat Jalan tidak diganti. Client menggabungkan response POS dan
  Backoffice dengan `sourceChannel` eksplisit.
- Tabel fulfillment tetap tidak mempunyai browser privilege; read memakai RPC
  tenant-scoped dan permission `inventory.delivery_documents:VIEW`.
- Migration hanya membuat function read-only. Kegagalan sebelum COMMIT rollback
  otomatis. Setelah COMMIT, rollback logis dilakukan dengan forward-fix yang
  revoke/drop function baru dan client kembali membaca endpoint POS saja.
- Production/staging tidak disentuh tanpa instruksi deployment eksplisit.

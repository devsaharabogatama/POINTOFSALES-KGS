# Purchase Order Generated Receipt Workflow

Target manual gate hanya isolated Development `fkywtxucmyjvpwdiqpix`.
Production dan staging tidak boleh disentuh pada gate ini.

## Alur yang dikunci

- MANUAL/AUTO_RO: RO dikonfirmasi, lalu sistem membuat PO dan dokumen Receipt.
- AUTO_PO: scheduler langsung membuat PO dan dokumen Receipt.
- PO tidak mempunyai aksi untuk memulai penerimaan.
- Gudang membuka dokumen yang sudah dibuat melalui `Purchase > Penerimaan Barang`.
- Save Receipt tidak mengubah Stock/FIFO/AP/Finance.
- Post Receipt memakai runtime canonical dan membuat quantity aktual menjadi
  billable. Tombol `Buat Bill` tetap berada pada PO dan memakai Faktur Supplier
  existing.
- Receipt partial membuat dokumen Receipt Draft berikutnya untuk sisa quantity.
- PO tetap editable hanya selama seluruh Receipt yang dibuat sistem belum mulai
  diisi/diposting.

## Impact dan compatibility

- Direct: trigger PO membuat satu Receipt Draft per Gudang tujuan; workspace
  Gudang membaca dokumen tersebut; API Save/Post merutekan scope DAILY_WAREHOUSE
  atau STORE ke runtime existing.
- Downstream: Stock/FIFO/AP/Finance tetap hanya berubah saat Receipt Post.
  Supplier Bill, Payment, Sales, POS, dan dokumen final lama tidak ditulis ulang.
- Existing open PO dengan Gudang tujuan valid mendapat Receipt Draft melalui
  backfill. Line tanpa Gudang tujuan tetap ada pada PO dan baru mendapat Receipt
  setelah PO diedit dengan Gudang tujuan valid.
- Retry Post tetap memakai idempotency key canonical. Unique index mencegah dua
  Receipt Draft aktif untuk pasangan PO/Gudang yang sama.
- Rollback teknis setelah migration applied menggunakan forward-fix; jangan drop
  Receipt, Stock, FIFO, AP, Bill, Payment, Journal, atau audit history.

## Urutan gate manual

1. Jalankan [preflight](../../../supabase/diagnostics/purchase_order_generated_receipt_workflow_preflight.sql) penuh.
2. Jika seluruh gate wajib PASS, jalankan [migration](../../../supabase/migrations/20260914180000_purchase_order_generated_receipt_workflow.sql) penuh.
3. Jalankan [behavioral test](../../../supabase/tests/purchase_order_generated_receipt_workflow_behavior.sql) penuh; seluruh mutation di-rollback.
4. Jalankan [postflight](../../../supabase/diagnostics/purchase_order_generated_receipt_workflow_postflight.sql) penuh.
5. Restart Backoffice lokal dan lakukan authenticated smoke.

## Authenticated smoke

1. Konfirmasi satu RO menjadi PO dan pastikan tidak ada tombol penerimaan pada PO.
2. Buka Penerimaan Barang; pastikan Receipt PO/Gudang sudah tersedia tanpa dibuat
   manual oleh Purchasing.
3. Terima sebagian quantity lalu Post. Pastikan Stock bertambah hanya setelah Post.
4. Kembali ke PO: status penerimaan Partial dan tombol `Buat Bill` tersedia.
5. Buat Bill dari PO dan pastikan Faktur Supplier existing memakai quantity yang
   sudah diterima tetapi belum ditagih.
6. Post sisa Receipt dan ulangi sampai PO selesai; pastikan tidak ada Receipt,
   Stock movement, AP, atau Bill ganda pada retry.
7. Pastikan form Receipt otomatis mengisi sisa quantity PO dan tetap editable.
8. Pilih sedikitnya dua Receipt, buka **Terima terpilih**, periksa detail setiap
   PO, lalu konfirmasi. Pastikan setiap Receipt berhasil secara independen dan
   Receipt yang gagal tetap Draft serta dapat diperbaiki tanpa membatalkan yang
   sudah berhasil.

Status: `LOCAL READY`; migration/behavior/postflight pada isolated Development,
authenticated smoke, dan UAT masih menunggu. Production/staging tidak disentuh.

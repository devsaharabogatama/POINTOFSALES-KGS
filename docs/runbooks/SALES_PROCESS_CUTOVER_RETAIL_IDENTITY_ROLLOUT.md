# Sales Process Cutover Retail Identity — Step 1D/6

Status: `DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS` pada isolated
Development `fkywtxucmyjvpwdiqpix`; client deployment, authenticated smoke, dan
UAT belum dijalankan.

## Outcome

Gate ini menyiapkan identitas target Retail hasil Office-to-Retail cutover tanpa
membuat Cashier Session atau POS Terminal palsu. Ia juga mengubah pending
Revision Retail dari requirement konversi menjadi item `BLOCKED` yang tetap
grandfathered pada source flow.

Gate ini belum menyediakan Apply, belum mengganti mode Company, dan belum
mengonversi Order apa pun.

## Impact map

- Direct: constraint dan trigger `sales_headers`, nullability `session_id`,
  `pos_id`, `created_session_id`, serta classifier cutover.
- Downstream: transaksi `POS` dan `BACKOFFICE_SALES` tetap wajib mempunyai tiga
  identitas sesi/terminal. Hanya `BACKOFFICE_CUTOVER + RETAIL_CONFIRM_INVOICE`
  yang wajib mempunyai ketiganya `NULL`.
- `source_channel` tidak diubah. Nilai itu membedakan sinkronisasi
  `ONLINE/OFFLINE`; sumber bisnis tetap berada pada `sales_origin`.
- Tidak ada write ke Reservation, procurement/PO, Dispatch/DO, Stock/FIFO,
  Invoice, Payment, cashier session, Finance queue/event/journal, setting mode,
  atau dokumen existing.

## Urutan manual — isolated Development saja

Project target wajib diverifikasi sebagai `fkywtxucmyjvpwdiqpix`. Jangan
menjalankan paket ini pada production/staging.

1. Jalankan
   `supabase/diagnostics/sales_process_cutover_retail_identity_preflight.sql`.
2. Stop jika ada `BLOCKER`. Open plan harus dibatalkan melalui RPC canonical,
   lalu preflight dijalankan ulang; jangan menghapus plan/item/audit.
3. Jalankan
   `supabase/migrations/20260910130000_sales_process_cutover_retail_identity.sql`.
4. Jalankan
   `supabase/tests/sales_process_cutover_retail_identity_behavior.sql`.
5. Jalankan
   `supabase/diagnostics/sales_process_cutover_retail_identity_postflight.sql`.
6. Stop pada SQL error atau `FAIL`. Kirim seluruh output sebelum Step Apply
   atomik dimulai.

## Behavioral coverage

- POS normal ditolak bila salah satu identitas sesi/terminal kosong.
- `BACKOFFICE_CUTOVER` Retail valid hanya bila seluruh identitas sesi/terminal
  kosong dan mode target adalah Retail.
- Pending Revision menjadi `BLOCKED` dengan kode stabil
  `PENDING_REVISION_MUST_RESOLVE`; classifier tidak lagi menghasilkan
  `CONVERT_REVISION_PAIR`.
- Invoice/procurement requirement pada candidate eligible tetap dipertahankan.
- Same-mode conversion tetap ditolak.

Behavioral SQL bersifat rollback-only dan tidak menyimpan fixture.

## Rollback / forward-fix

Sebelum target `BACKOFFICE_CUTOVER` pernah dibuat, rollback dapat mengembalikan
trigger/classifier lama, menghapus constraint/helper baru, lalu mengaktifkan
kembali `NOT NULL` pada tiga kolom identitas. Pastikan tidak ada baris NULL lebih
dulu.

Setelah target cutover pernah dibuat, jangan membuat sesi/terminal palsu dan
jangan menghapus histori. Gunakan forward-fix; nullability bersyarat dan origin
historis harus dipertahankan.

## Authenticated smoke yang masih menunggu

Apply belum tersedia pada gate ini. Setelah Apply dibangun, smoke wajib
mencakup Super Admin active-Company, stale plan/settings/source version, retry
operation ID, pending Revision grandfathering, Office-to-Retail tanpa sesi POS,
normal POS dengan sesi OPEN, multi-Company denial, dan rollback transaksi pada
satu conversion failure.

# Sales Process Cutover Persistent Preview Rollout

**Current step:** 1B/6 - persistent, version-locked preview plan.  
**Target:** isolated Supabase Development (`fkywtxucmyjvpwdiqpix`).  
**Production/staging:** do not run.

**Live status:** migration + closing postflight + behavioral rollback
user-confirmed PASS on isolated Development.

## Outcome

Gate `20260910110000` menyimpan output actual-data preview sebagai satu plan
`PREVIEWED` dan item per source document. Plan mengunci `settingsVersion`,
sedangkan setiap item mengunci `sourceMasterVersion`, status, decision, blocker,
requirement, dan source facts yang dibaca saat preview.

Hanya Platform Super Admin pada Company aktif yang dapat membuat atau membaca
plan melalui RPC. Create memakai advisory lock per Company, operation UUID,
SHA-256 request hash, exact retry, dan menolak payload berbeda dengan operation
UUID sama. Plan terbuka lain tidak diganti atau dibatalkan otomatis.

## Impact boundary

- Write hanya ke `sales_process_cutover_plans`, `sales_process_cutover_items`,
  `sales_process_cutover_audit`, dan migration ledger.
- Tidak mengubah `company_sales_process_settings`, feature entitlement, Order,
  Revision, Reservation, procurement/PO, Delivery/Dispatch, Stock/FIFO, Invoice,
  Payment, Finance queue/event/journal, atau POS/offline submission.
- `effective_at` hanya direkam sebagai input eksplisit; gate ini belum
  mengeksekusi waktu tersebut.
- Refresh, cancel, apply/conversion, dan switch mode masih tertutup.

## Manual execution

1. Pastikan SQL editor terhubung ke isolated Development project
   `fkywtxucmyjvpwdiqpix`, bukan production/staging.
2. Jalankan [preflight](../../supabase/diagnostics/sales_process_cutover_persistent_preview_preflight.sql).
3. Hentikan bila ada `BLOCKER`.
4. Jalankan [migration](../../supabase/migrations/20260910110000_sales_process_cutover_persistent_preview.sql).
5. Jalankan [behavioral test](../../supabase/tests/sales_process_cutover_persistent_preview_behavior.sql).
6. Jalankan [postflight](../../supabase/diagnostics/sales_process_cutover_persistent_preview_postflight.sql).
7. Kirim seluruh output. Jangan membuat plan manual atau melanjutkan apply saat
   ada SQL error, `BLOCKER`, atau `FAIL`.

## Compatibility and forward fix

- Existing preview RPC `get_sales_process_cutover_preview` tidak berubah.
- Tidak ada consumer POS/Backoffice yang dialihkan pada gate ini.
- Sebelum ada client consumer, isolated Development dapat menghapus empat RPC
  dan ledger row sebagai rollback. Sesudah consumer tersedia, gunakan
  forward-fix agar contract tidak hilang mendadak.
- Gate berikutnya baru boleh membangun refresh/cancel plan dengan optimistic
  drift check. Apply/switch tetap memerlukan gate terpisah dan persetujuan user.

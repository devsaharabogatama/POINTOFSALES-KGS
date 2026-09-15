# Sales Process Cutover Preview Runtime Rollout

**Current step:** 1A/6 - actual-data preview, no switch.  
**Target:** isolated Supabase Development.  
**Production/staging:** do not run.

## Outcome

Gate `20260909163000` menambah RPC Super Admin read-only untuk melihat dampak
switch Retail ke Office atau Office ke Retail pada Company aktif. Setiap dokumen
terbuka memperoleh keputusan `CONVERT`, `BLOCKED`, atau `KEEP_SOURCE`, blocker,
requirement, dan fakta source yang mendasarinya.

Pending Revision tidak diduplikasi: source dan replacement ditampilkan sebagai
satu pair. Preview memeriksa Reservation, procurement/PO lineage, Dispatch,
final Stock effect, Invoice, Payment, Finance, Offline submission, active
Finance queue, dan entitlement.

Riwayat pembayaran Retail dibaca dari `sales_payments` dan verification request.
Semua event Finance `POSTED` yang memakai root Sales terkait juga menjadi
blocker konversi, bukan hanya event Dispatch.

Mode bisnis dan entitlement dipisah. Ketika Office ke Retail, entitlement
Backoffice tetap diperlukan untuk menyelesaikan dokumen Office historis dan
tidak boleh otomatis dimatikan oleh switch.

## Manual execution

1. Jalankan [preflight](../../supabase/diagnostics/sales_process_cutover_preview_preflight.sql).
2. Hentikan bila ada `BLOCKER`.
3. Jalankan [migration](../../supabase/migrations/20260909163000_sales_process_cutover_preview_runtime.sql).
4. Jalankan [behavioral test](../../supabase/tests/sales_process_cutover_preview_behavior.sql).
5. Jalankan [postflight](../../supabase/diagnostics/sales_process_cutover_preview_postflight.sql).
6. Kirim seluruh output sebelum plan/apply runtime dibuat.

## Compatibility and rollback

- Migration hanya membuat dua function dan ledger row; tidak menulis plan atau
  dokumen operasional.
- Rollback sebelum consumer UI: drop public wrapper, drop private core, lalu
  hapus ledger row hanya pada isolated Development. Sesudah dipakai client,
  gunakan forward-fix agar public contract tidak hilang mendadak.
- Gate berikutnya membuat persistent preview plan dengan expected setting dan
  document version. Apply/switch tetap belum diizinkan pada gate ini.

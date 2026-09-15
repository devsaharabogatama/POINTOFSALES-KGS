# Sales Process Cutover Atomic Apply — Step 4E/6

Status: **DATABASE LIVE; CORRECTED BEHAVIOR USER-CONFIRMED PASS;
FINAL POSTFLIGHT CONFIRMATION PENDING ON ISOLATED DEVELOPMENT**.

Target manual hanya Supabase Development `fkywtxucmyjvpwdiqpix`.
Production/staging tidak disentuh.

## Outcome

Historical-clone evidence (2026-09-15, `idrufihckscppsyclmsu`, unit 45/88):
nine preflight checks PASS; migration installed; rollback-only behavioral PASS;
nine closing postflight checks PASS. Actual applied plans, converted items and
mode switches remain zero after rollback. This does not establish Production
rollout, authenticated UI smoke, UAT, or final fresh-clone compatibility.

Step ini membuka Apply manual untuk plan `PREVIEWED` dan menjadikan
`company_sales_process_settings.active_mode` otoritas pembuatan transaksi root:

- Apply hanya dapat dipanggil Platform Super Admin pada Company aktif;
- `effective_at`, optimistic plan/settings version, live preview, source version,
  Finance queue, Offline submission, entitlement, dan direction divalidasi ulang;
- item `CONVERT` memakai private converter canonical dua arah;
- item `BLOCKED`/`KEEP_SOURCE` ditandai `KEPT` dan tetap diselesaikan melalui
  runtime source/grandfathered;
- mode history, target lineage, item audit, plan `APPLIED`, dan Company mode
  berubah dalam satu transaksi;
- satu kegagalan me-rollback seluruh conversion dan mode switch;
- exact retry mengembalikan response yang sama tanpa target duplikat;
- setelah switch, root baru hanya dapat dibuat pada mode aktif. Existing source
  tetap dapat diedit/diselesaikan; Revision Retail lama memakai marker lineage
  internal, bukan bypass dari payload browser;
- Offline envelope baru ditolak sebelum masuk queue bila Retail bukan mode aktif.

## Impact map

Direct impact:

- RPC `apply_sales_process_cutover_plan`;
- plan/item/audit cutover dan immutable Company mode history;
- trigger creation gate `sales_headers` dan `backoffice_sales_orders`;
- wrapper submit Offline dan start Revision Retail;
- source/target Quotation/SO/Draft Retail melalui converter Step 4B/4C.

Downstream yang harus tetap nol dari switch itu sendiri:

- Stock Movement, On Hand, FIFO/COGS;
- Payment, Cash Drawer dan Cashier Session final effect;
- Invoice/SJ/DO dispatch baru di luar mapping converter;
- Finance Event, posting queue dan Journal.

Compatibility:

- dokumen final tidak dikonversi;
- item blocked tidak menghalangi mode switch dan tidak kehilangan source;
- entitlement Backoffice tidak otomatis dimatikan ketika kembali ke Retail,
  karena dokumen grandfathered Backoffice masih membutuhkannya;
- identitas `sales_process_mode` dokumen lama tidak ditulis ulang;
- migration sebelumnya tidak diedit.

## Urutan manual

1. Pastikan SQL Editor menunjuk Development `fkywtxucmyjvpwdiqpix`.
2. Jalankan seluruh [preflight](../../supabase/diagnostics/sales_process_cutover_atomic_apply_preflight.sql).
3. Stop pada SQL error atau `BLOCKER`. `step_4e_behavior_fixture` wajib `PASS`;
   seluruh perubahan fixture maupun candidate existing tetap berada dalam
   transaksi rollback-only.
4. Jalankan [migration](../../supabase/migrations/20260911130000_sales_process_cutover_atomic_apply.sql).
5. Jalankan seluruh [behavioral test](../../supabase/tests/sales_process_cutover_atomic_apply_behavior.sql).
   Test membentuk satu source convertible dan satu future non-TEMPO blocker,
   menguji stale preview lalu refresh/Apply, dan melakukan `ROLLBACK` penuh.
6. Jalankan [postflight](../../supabase/diagnostics/sales_process_cutover_atomic_apply_postflight.sql).
7. Kirim satu row hasil behavior dan seluruh row postflight.

Jangan menjalankan Apply terhadap data nyata melalui SQL Editor. Authenticated
smoke dan UI Platform untuk create/refresh/cancel/apply plan baru dibuka pada
Step 4F setelah gate ini lulus.

## Evidence lokal

- audit call chain: root Retail terpusat pada trigger `sales_headers`; Backoffice
  pada insert `backoffice_sales_orders`; Offline queue masuk melalui
  `submit_pos_offline_sale`; Revision replacement melalui
  `start_pos_sales_order_revision`;
- migration/preflight/behavior/postflight delimiter dan transaction boundary
  seimbang;
- scoped `git diff --check`: PASS;
- SQL tidak dijalankan agent; user mengonfirmasi migration terpasang dan
  corrected rollback-only behavior PASS pada isolated Development;
- migration SHA-256:
  `e66176541bef723428deafe8056731f09ca0aa743a4526ecef6d767be8574672`;
- preflight SHA-256:
  `8039e509377cd48da387ae2975a8df67fb7af537109ddade48bd0f6e3604ae00`;
- behavior SHA-256:
  `3dd5190119fbf049c75961bc7e259741005e2ec16ab7fdf59e126569ab577ef7`;
- postflight SHA-256:
  `88373429c975356d72720e94a92bd8cdcb971288280796c019cbc48e790aded6`.

## Rollback / forward-fix

SQL error sebelum `COMMIT` merollback seluruh object Step 4E. Setelah ledger
terpasang, jangan edit migration ini. Defect wajib diperbaiki dengan forward
migration. Apply operasional bersifat atomik; error tidak boleh meninggalkan
target, source cancellation, item status, history, atau mode parsial. Mode yang
sudah berhasil di-Apply tidak di-rollback dengan update manual; gunakan plan
switch baru ke mode sebelumnya agar histori tetap append-only.

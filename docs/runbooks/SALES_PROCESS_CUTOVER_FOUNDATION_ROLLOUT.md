# Sales Process Cutover Foundation Rollout

**Current step:** 1A/6 — foundation only.  
**Target:** isolated Supabase Development.  
**Production/staging:** do not run.

## Outcome

Gate `20260909162000` menyiapkan mode Company default Retail, immutable mode
history, cutover plan/item/audit lineage, serta classifier eligible/blocker dua
arah. Migration tidak mengganti mode Company dan tidak mengonversi Order.

## Impact boundary

- Direct: lima relation foundation, tiga private routine, tiga trigger.
- Preserved: POS/Backoffice creation, Reservation, PO/procurement, Stock/FIFO,
  Delivery/Transit, Invoice, Payment, Financial Event, Journal dan UI.
- Backfill: satu setting dan satu history `INITIALIZE` ber-mode Retail per
  Company; belum dikonsumsi runtime sehingga tidak mengubah flow aktif.
- Rollback: sebelum runtime berikutnya, relation/routine/trigger dapat dihapus
  dalam urutan dependency setelah memastikan plan/item/audit tetap nol. Setelah
  ada cutover history, gunakan forward-fix; jangan drop audit.

## Manual execution order

1. Jalankan [preflight](../../supabase/diagnostics/sales_process_cutover_foundation_preflight.sql).
2. Hentikan bila ada `BLOCKER`.
3. Jalankan [migration](../../supabase/migrations/20260909162000_sales_process_cutover_foundation.sql).
4. Jalankan [behavioral test](../../supabase/tests/sales_process_cutover_foundation_behavior.sql).
5. Jalankan [postflight](../../supabase/diagnostics/sales_process_cutover_foundation_postflight.sql).
6. Kirim seluruh hasil. Jangan melanjutkan ke preview/runtime conversion bila
   behavior bukan PASS atau postflight memiliki FAIL.

## Behavioral boundary berikutnya

Gate selanjutnya harus membangun preview dari data nyata dan membuktikan:

- Draft/Scheduled/Pending Revision dapat dikonversi sebagai lineage bundle;
- Invoice Retail yang belum mempunyai Payment/Dispatch/Finance hanya masuk
  requirement formal cancellation;
- Dispatch, final Stock/FIFO, posted Finance, dan Payment unresolved menjadi
  blocker;
- open procurement/PO tidak dihapus dan harus mempunyai transfer lineage;
- retry, stale setting version, concurrent switch, cross-Company, Offline late
  submission dan switch balik Office ke Retail fail-closed.

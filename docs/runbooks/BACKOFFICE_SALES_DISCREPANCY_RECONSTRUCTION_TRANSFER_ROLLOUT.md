# Backoffice Sales — Discrepancy Reconstruction Transfer (Step 4/6.5C1)

## 2026-09-15 historical-clone rehearsal evidence

Unit 59 clone `idrufihckscppsyclmsu`: preflight four PASS, initial/closing
postflight four PASS, rollback-only behavior nine scenarios PASS. Auth-backed
actor/Office preparation corrected; setup marker cleared and root guard asserted
before operational RPCs. Warehouse OFF denies shortage; ON transfers actual FIFO
plus provisional shortage 1 to exact DO Transit. Stock/FIFO reconcile and case
remains pending. Runtime/installed migrations unchanged by test fix.
Goods Receipt revaluation, full Wrong Item matrix and authenticated UI smoke/UAT
not proven here. Production/client untouched. Stopped before unit 60 because
its UPDATE WHERE false fixture does not provide representative behavior evidence.

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED
DEVELOPMENT; AUTHENTICATED UI SMOKE/UAT PENDING**.

Target hanya isolated Development `fkywtxucmyjvpwdiqpix`. Production
`nbxjslqojexjfogamnjt` dan staging lama `yjxpddwrjdczuqyix` dilarang.

## Tujuan dan impact

Helper private membentuk fakta Stock actual Overage/Wrong Item dari Gudang asal
ke Transit DO memakai FIFO canonical. Shortage hanya diizinkan oleh
`Warehouse.allow_negative_stock` dan memiliki negative-allocation lineage untuk
revaluasi saat Goods Receipt. Company, discrepancy, DO, Reservation, Product,
quantity, Transit, version, dan idempotency dikunci server-side.

Gate ini belum mengubah status discrepancy, belum membuat Stock Effect final,
belum membuat Financial Event, dan tidak membuka RPC browser. Step 4/6.5C2 akan
memakai helper untuk Return/Accept serta membuat Financial Event accepted
overage terpisah agar penerimaan awal tetap immutable.

## Urutan manual

1. `supabase/diagnostics/backoffice_sales_discrepancy_reconstruction_transfer_preflight.sql`
2. Pastikan seluruh row selain `INFO` adalah `PASS`.
3. `supabase/migrations/20260912122000_backoffice_sales_discrepancy_reconstruction_transfer.sql`
4. `supabase/diagnostics/backoffice_sales_discrepancy_reconstruction_transfer_postflight.sql`
5. `supabase/tests/backoffice_sales_discrepancy_reconstruction_transfer_behavior.sql`
6. Jalankan postflight sekali lagi.

Behavior rollback-only membuat SO/DO/Dispatch/Receipt Overage canonical,
membuktikan policy OFF menolak shortage, policy ON membuat FIFO plus negative
allocation, dan helper tidak menyelesaikan discrepancy secara prematur.

Stop pada SQL error, `BLOCKER`, atau `FAIL`. Migration applied tidak boleh
diedit/rerun; koreksi harus forward migration baru.

## Evidence manual

Pada 2026-09-12 user mengonfirmasi preflight, migration, postflight, dan
behavioral test seluruhnya PASS pada isolated Development. C1 tetap bukan
resolver operasional: status discrepancy dan Financial Event baru akan dibuat
oleh C2.

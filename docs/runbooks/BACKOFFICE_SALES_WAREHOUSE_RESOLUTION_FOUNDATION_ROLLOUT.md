# Backoffice Sales — Warehouse Resolution Foundation (Step 4/6.5A)

## 2026-09-15 historical-clone rehearsal evidence

Unit 56 clone `idrufihckscppsyclmsu`: preflight ten PASS, initial/closing
postflight eight PASS, rollback-only constraint behavior seven scenarios PASS.
Fixture uses Auth-backed actor and Office setup cleared before Sales RPCs.
Assertions follow installed ledger version: ordered 4/approved 1 allows accepted
5 before `20260912137000`; after split regular accepted is bounded to 4.
Excess rejected in either branch. Only pre-split branch executed in this rehearsal;
post-split regression remains pending. Direct ledger edits are isolated constraint
tests, not proof of physical Warehouse resolution. Runtime/constraints unchanged.
Stopped before unit 57 on missing Office fixture setup. Production/client and
authenticated UI smoke/UAT untouched/pending.

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.

Target yang diizinkan hanya isolated Development `fkywtxucmyjvpwdiqpix`.
Jangan jalankan paket ini pada production `nbxjslqojexjfogamnjt` atau staging lama
`yjxpddwrjdczuqyix`.

## Tujuan dan batas step

Step ini mengunci struktur data yang akan dipakai resolver Gudang berikutnya.
Belum ada RPC publik untuk menyelesaikan discrepancy dan belum ada Stock/FIFO,
Backorder, Invoice, Payment, atau Journal baru yang dijalankan oleh step ini.

- `ACCEPT_OVERAGE` yang sudah disetujui Sales tetap menunggu resolution Gudang.
- SO menyimpan batas/evidence `approved_overage_base_qty`. Setelah forward-fix
  `137000`, quantity accepted regular tidak boleh melebihi ordered quantity;
  accepted overage berada pada ledger discrepancy terpisah.
- Efek Stock menyimpan pasangan movement, exact Product/Gudang, quantity, biaya,
  operation, discrepancy, dan line sumber.
- Allocation FIFO mengikat setiap efek ke batch Transit/sumber dan batch tujuan
  yang tepat.
- Backorder mengikat DO/SJ tambahan ke discrepancy, DO awal, SO, serta line
  sumbernya. Reservation expected tidak diperbesar oleh accepted overage.
- Lost/damaged tetap menunggu resolver operasional dan Finance `HOLD`; step ini
  hanya menyediakan relasi untuk lineage tersebut.

## Impact map

- Direct: constraint quantity SO line, classifier discrepancy, empat relasi
  immutable untuk Stock effect/FIFO/Backorder, serta validator private.
- Downstream: resolver Gudang Step 4/6.5B wajib mengisi lineage ini dalam satu
  transaksi sebelum menandai discrepancy resolved.
- Tidak berubah: RPC clean/mixed receipt, dispatch, POS Retail, Invoice client,
  Payment, Cashier Session, posting Finance, template Invoice/SJ, dan UI.
- Data lama: accepted overage `NOT_REQUIRED` dinormalisasi menjadi `PENDING`;
  header discrepancy terkait menjadi membutuhkan Warehouse resolution. Tidak
  ada hasil fisik, batch, atau movement yang direka untuk data lama.
- Concurrency/idempotency: belum dibuka ke browser. Runtime berikutnya wajib
  memakai header version dan operation UUID existing serta lock dokumen/batch.
- Rollback: forward-only. Jika belum ada efek operasional, koreksi dilakukan
  dengan migration additive/forward fix; history yang sudah tercatat tidak
  boleh dihapus atau diubah.

## Urutan manual

Jalankan seluruh isi file, bukan selected text:

1. `supabase/diagnostics/backoffice_sales_warehouse_resolution_foundation_preflight.sql`
2. Pastikan semua baris selain `INFO` adalah `PASS`.
3. `supabase/migrations/20260912110000_backoffice_sales_warehouse_resolution_foundation.sql`
4. `supabase/diagnostics/backoffice_sales_warehouse_resolution_foundation_postflight.sql`
5. `supabase/tests/backoffice_sales_warehouse_resolution_foundation_behavior.sql`
6. Jalankan postflight sekali lagi.

Behavioral test bersifat rollback-only. Fixture dibuat melalui RPC SO canonical,
menguji overage tanpa approval ditolak, approved overage membuka Qty To Invoice
dalam batas tepat, kelebihan di atas approval ditolak, classifier mewajibkan
Sales dan Warehouse, serta memastikan resolver publik belum aktif.

## Stop condition

Hentikan urutan jika ada `BLOCKER`, `FAIL`, atau SQL error. Jangan menjalankan
migration ulang jika ledger `20260912110000` sudah ada; kirim output lengkap
untuk dibuatkan forward fix bila diperlukan.

## Status gate

- LOCAL READY: file dan static audit selesai.
- DATABASE LIVE: ya, pada isolated Development; behavior/postflight dikonfirmasi PASS oleh user.
- CLIENT DEPLOYED: belum; tidak ada perubahan client pada foundation ini.
- SMOKE PASS: belum; resolver/UI belum dibuka.
- UAT PASS: belum.

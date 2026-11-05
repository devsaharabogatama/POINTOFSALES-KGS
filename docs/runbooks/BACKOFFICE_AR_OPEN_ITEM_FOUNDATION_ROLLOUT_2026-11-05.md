# Backoffice AR Open-Item Foundation — Rollout 2026-11-05

Status repository: **DATABASE LIVE / FIRST+CLOSING POSTFLIGHT + ROLLBACK
BEHAVIOR PASS**. First target
attempt rolled back on the heterogeneous audit trigger; repeated preflight
proved `NOT_INSTALLED`, then the corrected migration installed successfully.
Database rollout is closed. Authenticated client read smoke and UAT remain
pending.

## Scope

Task 2 hanya memasang registry/slice open-item Backoffice, append-only allocation
dan audit ledger, serta RPC baca Finance. Migration tidak mengubah Posted
Journal, posting Invoice/Receipt/Credit Note, Return/Refund, POS Retail,
Customer Balance, Stock/FIFO, atau data master.

## Urutan manual wajib

Jalankan sebagai satu file utuh pada database target, jangan potong statement:

1. `supabase/diagnostics/backoffice_ar_open_item_foundation_preflight.sql`
2. Pastikan seluruh row mandatory berstatus `PASS`. Row `INFO` bukan failure.
3. `supabase/migrations/20261105100000_backoffice_ar_open_item_foundation.sql`
4. `supabase/diagnostics/backoffice_ar_open_item_foundation_postflight.sql`
5. `supabase/tests/backoffice_ar_open_item_foundation_behavior.sql`
6. Jalankan postflight sekali lagi setelah behavior rollback.
7. Authenticated smoke: login sebagai user Finance yang mempunyai
   `finance.customer_receipts / VIEW`, pilih Company KMS, LSM, lalu SMS, dan
   panggil `get_finance_ar_open_items(null,false)` melalui client/API resmi.

Jangan lanjut jika preflight berstatus `BLOCKER`, migration error, postflight
`FAIL`, behavior tidak `PASS`, atau authenticated smoke tidak dapat membaca
Company aktif yang benar.

## Expected evidence

- state preflight `NOT_INSTALLED`;
- migration ledger tepat satu row `20261105100000`;
- source count dan registry count sama;
- tidak ada over-allocation;
- jumlah audit sama dengan seluruh insert registry/operation/allocation;
- setiap audit actor/snapshot cocok dengan `registry.created_by`,
  `operations.actor_id`, atau `allocations.created_by` sesuai entity kind;
- authenticated hanya dapat memakai RPC, bukan membaca tabel langsung;
- behavior mengembalikan satu row `PASS` dan seluruh test write di-rollback.

## Rollback / forward-fix

Migration menyimpan snapshot historis append-only dan tidak menyediakan
down-migration. Setelah `DATABASE LIVE`, jangan menghapus ledger, tabel, atau
row hasil backfill dan jangan mengubah migration ini. Koreksi wajib memakai
forward migration baru setelah audit dampak. Sebelum live, rollback berasal
dari transaksi migration yang otomatis batal penuh apabila guard/assertion
gagal.

## Status yang tidak boleh dilompati

- `AUDIT COMPLETE`: sudah.
- `LOCAL READY`: hanya setelah seluruh static gate repository PASS.
- `DATABASE LIVE`: hanya setelah migration dan postflight target PASS.
- `SMOKE PASS`: hanya setelah authenticated RPC smoke per Company PASS.
- `UAT PASS`: belum termasuk Task 2; UI allocation manual adalah Task 3.

# Backoffice Sales Accepted-Overage Ledger Split Forward-Fix

## Clone rehearsal evidence — 2026-09-15

Unit 70 applied only on `idrufihckscppsyclmsu`: eight preflight and eight postflight
checks PASS; C3 twelve-scenario rollback retest PASS with finalLedgerSplitVerified=true.
Regular Order 4 plus accepted overage 1 yields combined Qty To Invoice 5, not 6.
No historical overage rows required backfill in this clone; zero rows are not the
behavioral proof. Production/client untouched; authenticated UI smoke/UAT and fresh
Production comparison remain required. Existing manual-development status below is
historical and does not authorize production deployment.


Status: **LOCAL READY; MANUAL ISOLATED-DEVELOPMENT DATABASE GATE PENDING**.

Target hanya Supabase Development terisolasi `fkywtxucmyjvpwdiqpix`.
Production dan staging tidak boleh dipakai untuk rollout ini.

## Root cause yang dibuktikan

Resolver C3 aktif mencatat quantity accepted overage pada dua ledger sekaligus:

- `backoffice_sales_order_lines.accepted_base_qty`, yaitu source Invoice regular;
- `backoffice_sales_delivery_discrepancy_lines.accepted_overage_base_qty`, yaitu
  source Invoice `ACCEPTED_OVERAGE`.

Read-model dan runtime Invoice memang memperlakukan kedua ledger tersebut
sebagai source terpisah. Akibatnya satu accepted overage dapat muncul dua kali
sebagai Qty To Invoice. Behavioral C3 lama juga mengunci hasil yang salah
(`accepted_base_qty=ordered+overage`) sehingga defect tersebut tidak tertangkap.

## Perbaikan dan impact map

- Resolver tetap menambah `approved_overage_base_qty` sebagai batas/evidence
  resolution, tetapi tidak lagi menambah ledger accepted quantity regular.
- `accepted_base_qty`, Return regular, Draft allocation regular, dan Posted
  allocation regular kembali dibatasi hanya oleh `ordered_base_qty`.
- Quantity overage tetap disimpan, dialokasikan, dibatalkan, dan diposting hanya
  melalui counter discrepancy `ACCEPTED_OVERAGE`.
- Data legacy hanya dikoreksi dengan mengurangi exact total accepted overage
  dari accepted quantity regular bila kedua ledger cocok satu-ke-satu dan belum
  ada Draft/Posted allocation regular yang memakai bagian overage.
- Jika source tidak cocok atau Invoice regular mungkin sudah memakai overage,
  preflight/migration berhenti. Tidak ada Invoice atau Journal historis yang
  ditulis ulang otomatis.

Tidak berubah: Stock, FIFO, Reservation, DO/SJ, approval komersial, event COGS,
Finance Posting Queue, Payment, template Invoice, POS Retail, Cashier Session,
role, tenant, atau public RPC.

## Urutan manual wajib

Jalankan file secara utuh dan satu per satu:

1. [Preflight read-only](../../supabase/diagnostics/backoffice_sales_accepted_overage_ledger_split_fix_preflight.sql)
2. [Migration forward-fix](../../supabase/migrations/20260912137000_backoffice_sales_accepted_overage_ledger_split_fix.sql)
3. [Behavioral C3 rollback-only](../../supabase/tests/backoffice_sales_overage_wrong_item_resolution_behavior.sql)
4. [Postflight read-only](../../supabase/diagnostics/backoffice_sales_accepted_overage_ledger_split_fix_postflight.sql)

Stop jika preflight menghasilkan `BLOCKER`, migration/test menghasilkan SQL
error, atau postflight menghasilkan `FAIL`. `INFO` dengan nol row bukan bukti
behavior; bukti behavioral berasal dari resolver C3 yang membuat accepted
overage nyata di dalam transaksi lalu `ROLLBACK`.

## Acceptance criteria

- SO line contoh Order 4 + accepted overage 1 tetap mempunyai regular accepted
  4 dan regular Qty To Invoice 4.
- Discrepancy line mempunyai accepted-overage Qty To Invoice 1.
- Total combined Qty To Invoice tepat 5, bukan 6.
- Exact retry, stale version, Stock/FIFO effect, child correction DO/SJ, dan
  separate COGS Event pada behavior C3 tetap lulus.
- Postflight membuktikan resolver/security/private boundary, constraint regular,
  source reconciliation, dan Invoice reader tetap konsisten.

## Rollback / forward-fix

Migration berjalan transactional. Error sebelum `COMMIT` mengembalikan schema,
data, constraint, dan function definition. Setelah ledger `137000` tercatat,
jangan mengembalikan double-ledger behavior dan jangan mengedit migration yang
sudah applied. Koreksi berikutnya wajib additive. Data ambigu harus diselesaikan
melalui audit dokumen/Invoice yang eksplisit, bukan backfill tebakan.

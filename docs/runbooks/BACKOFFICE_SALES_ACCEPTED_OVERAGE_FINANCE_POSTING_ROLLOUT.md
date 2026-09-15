# Backoffice Sales Accepted-Overage Finance Posting — Step 5/6.1

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED
DEVELOPMENT; AUTHENTICATED SMOKE/UAT PENDING**.

Target hanya project Development terisolasi `fkywtxucmyjvpwdiqpix`.
Production `nbxjslqojexjfogamnjt` dan staging lama `yjxpddwrjdczuqyix`
tidak boleh dipakai untuk rollout ini.

## Historical clone evidence — 2026-09-15

- Unit 67 installed on clone `idrufihckscppsyclmsu` only. Preflight seven PASS,
  initial/closing postflight nine PASS each; rollback-only behavior 12 reported
  scenarios PASS including balanced Journal, cross-tenant denial, retry/stale
  version and zero posting Stock/Invoice/Payment delta.
- Fixture selects Auth-backed actor and sets Office mode under Company lock;
  marker cleared/root guard asserted before operational RPC. Runtime unchanged.
- Private-core behavioral evidence, not full public queue/permission or browser
  smoke. Prior-period/concurrency matrix and final ledger split remain pending.
- Stop before Stock Loss group 68–69: ADJUSTMENT source mismatch needs existing
  movement-type forward-fix. Unit 68 preflight PASS/SETUP only, no migration.
  Progress 67/88; no Production/client changes. Forward-fix for applied SQL only.

## Outcome dan impact map

- Event `BACKOFFICE_ACCEPTED_OVERAGE_COGS` yang sudah dibuat `HOLD` oleh
  resolution Gudang menjadi eligible pada Posting Queue Finance existing.
- Posting merekonsiliasi immutable stock effect, exact FIFO allocation,
  Stock Movement, discrepancy/SO/DO identity, mapping, dan rule version.
- Journal: debit COGS dan kredit Inventory Asset pada Transit Warehouse.
- Tanggal ekonomi memakai tanggal Customer menerima. Jika periodenya sudah
  tertutup, perilaku mengikuti receipt COGS existing: prior-period adjustment
  pada periode terbuka berikutnya; tanpa periode postable, transaksi ditolak.
- Direct impact hanya dispatcher/support predicate Finance dan private posting
  core. Tidak ada public RPC atau UI baru.
- Tidak mengubah Stock/FIFO, Qty To Invoice, Invoice, Payment, POS Retail,
  Cashier Session, template dokumen, atau proses cutover.
- Retry event yang sudah Posted mengembalikan Journal yang sama. Stale version,
  cross-tenant, source/cost drift, dan mapping ambigu ditolak transactional.

## Urutan manual wajib

1. [Preflight](../../supabase/diagnostics/backoffice_sales_accepted_overage_finance_posting_preflight.sql)
2. [Migration](../../supabase/migrations/20260912134000_backoffice_sales_accepted_overage_finance_posting.sql)
3. [Behavioral rollback-only](../../supabase/tests/backoffice_sales_accepted_overage_finance_posting_behavior.sql)
4. [Postflight](../../supabase/diagnostics/backoffice_sales_accepted_overage_finance_posting_postflight.sql)
5. Jalankan postflight sekali lagi setelah behavioral PASS.

Jalankan setiap file secara utuh. Stop pada SQL error, `BLOCKER`, atau `FAIL`.
Migration jangan dijalankan ulang setelah ledger `20260912134000` tercatat.

## Authenticated smoke setelah seluruh SQL PASS

1. Di Backoffice Development, buat SO dan selesaikan DO dengan accepted overage.
2. Approve nilai komersial dari SO, lalu selesaikan fisiknya dari Surat Jalan.
3. Buka Finance → Posting Queue. Event "HPP Kelebihan Diterima" harus muncul.
4. Jalankan proses sesuai policy Finance Company.
5. Pastikan Event menjadi Posted tepat sekali dan Journal berisi dua baris:
   debit COGS dan kredit Inventory Asset dengan nilai sama.
6. Pastikan Invoice, Qty To Invoice, histori pembayaran, dan Stock tidak berubah
   ketika Finance mem-post event ini.
7. Uji retry, stale tab, user tanpa akses Finance, dan ganti Company.

## Rollback / forward-fix

Sebelum migration applied, rollback adalah tidak menjalankan paket. Setelah
ledger tercatat, jangan menghapus wrapper, Event, atau Journal. Koreksi harus
menggunakan migration forward-only yang menjaga dispatcher chain dan immutable
Finance history.

# Office Sales + Daily Purchase — Production Rollout Preparation

Status: `READ-ONLY AUDIT PACKAGE AUTHORIZED; MANUAL PRODUCTION EXECUTION PENDING;
PRODUCTION MUTATION/ROLLOUT NOT AUTHORIZED`.

Latest user decision 2026-09-15: reuse the completed clone rehearsal. First run
the [Production delta read-only package](OFFICE_PURCHASE_PRODUCTION_DELTA_READ_ONLY.md).
Do not automatically repeat 88 migrations or require a fresh clone due to count/
digest differences. Another clone is conditional on identified relevant drift that
cannot be represented/proved on the current clone. Historical Stage B below records
the rehearsal method, not a new mandatory full replay after its completed run.

Dokumen ini menyiapkan pemasangan bisnis proses Office dan Purchase harian
tanpa reset, truncate, atau penghapusan transaksi production. Tidak ada klaim
production-ready sebelum seluruh bukti di bawah tersedia.

## Batas wajib

- Jangan memakai `supabase db reset`, `db push`, seed development, atau fixture
  test pada production.
- Jangan menghapus transaksi Retail, draft terjadwal, revisi, pembayaran,
  Stock Movement, FIFO, AR/AP, Financial Event, Journal, Receipt, atau Return.
- Business process seluruh Company tetap seperti production saat ini setelah
  migration. Perubahan mode hanya melalui preview/cutover eksplisit per Company.
- Daily Purchase default tetap `MANUAL`; scheduler tidak boleh membuat RO/PO
  sampai setting Company secara eksplisit diubah setelah smoke.
- Client baru tidak boleh dipasang sebelum database chain dan postflight batch
  yang dibutuhkan client sudah PASS.
- Production hanya disentuh setelah instruksi user terpisah.

## Fakta source saat preparation

- Candidate chain lokal saat ini: 89 migration dari `20260908100000` sampai
  `20260914180000`.
- Pembagian candidate: 29 Sales foundation, 15 cutover/compatibility, 27 Sales
  operational/Finance/discrepancy, dan 11 Purchase.
- Angka 89 bukan jumlah migration yang pasti harus dijalankan. Delta final
  wajib berasal dari ledger production aktual karena beberapa hotfix production
  mungkin sudah terpasang terpisah.
- Static scan menemukan definisi runtime yang mengandung edit/delete Draft.
  Itu bukan izin menghapus transaksi production; rehearsal wajib membuktikan
  migration-time effect dan runtime final tidak mengubah histori final.

## Tahap A — discovery read-only

1. Ambil backup/PITR status dan retention dari dashboard Supabase.
2. Jalankan penuh
   `supabase/diagnostics/office_purchase_production_discovery_preflight.sql`.
3. Simpan hasil lengkap, terutama environment identity, seluruh versi candidate
   yang sudah ada di application ledger, active Finance queue, Offline queue,
   object inventory, dan row-count transaksi.
4. Cocokkan ledger production dengan `supabase/MIGRATION_MANIFEST.md`. Jangan
   menyusun delta hanya dari timestamp filename.
5. Jika ada routine/object dengan versi tidak dikenal atau checksum source
   berbeda, stop. Buat compatibility forward-fix; jangan overwrite diam-diam.
6. Catat inventori PO terbuka. Migration `20260914180000` dapat menambahkan
   satu Receipt Draft per pasangan PO/Gudang yang masih mempunyai quantity
   terbuka. Ini bukan perubahan dokumen final, tetapi tetap merupakan backfill
   child transaction dan wajib direkonsiliasi di clone sebelum production.

Discovery hanya membaca data. `PASS` pada tahap ini belum mengizinkan migration.

## Tahap B — clone rehearsal dengan data production

1. Buat clone/restore production pada project rehearsal terpisah.
2. Verifikasi count dan identifier dokumen clone sama dengan snapshot discovery.
3. Terapkan hanya delta migration hasil ledger, satu per satu, sesuai manifest.
4. Setelah setiap kelompok jalankan postflight terkait dan hentikan pada satu
   `BLOCKER`, `FAIL`, SQL error, timeout, atau unexpected row mutation.
5. Jalankan behavioral test hanya yang eksplisit rollback-only. Jangan memakai
   test yang membutuhkan fixture development pada data clone tanpa review.
6. Jalankan authenticated matrix:
   - Retail POS Draft/Confirm, scheduled order, revision, SJ/Invoice, cancel;
   - Cash/TEMPO, partial/full payment, posting queue, AR dan jurnal;
   - Office Quotation → SO → Reserve → DO → Receive → Invoice → Post → Paid;
   - discrepancy/Return/Backorder/Transit;
   - Purchase MANUAL RO → PO → multi-Warehouse Receipt → Bill → Payment;
   - AUTO_RO/AUTO_PO pada Company fixture khusus, termasuk exact retry 23.59;
   - dua Company, role denial, stale version, idempotent retry, dan concurrency.
7. Catat waktu ALTER/lock serta total maintenance window hasil rehearsal.
8. Tepat sebelum `20260914180000`, simpan daftar PO/Gudang kandidat Receipt
   Draft. Setelah migration, cocokkan setiap Draft baru satu-ke-satu dengan
   daftar tersebut dan pastikan tidak ada Receipt/Stock/FIFO/AP/Journal final
   yang terbentuk oleh backfill.

## Tahap C — bukti preservasi data

Bandingkan sebelum/sesudah rehearsal dan nanti production:

- jumlah serta ID/nomor `sales_headers` dan line existing;
- tanggal order/kirim/jatuh tempo dan Invoice snapshot existing;
- saldo On Hand, Reserved, Transit, total Stock Movement, dan FIFO value;
- Cashier Session, payment, Customer Balance, AR/AP outstanding;
- jumlah dan total Financial Event/Journal per Company/periode;
- Supplier Order, Goods Receipt, Purchase Return, Supplier Invoice/Payment;
- tidak ada final document berubah menjadi Draft/Canceled dan tidak ada nomor
  dokumen existing dibuat ulang.

Perbedaan hanya boleh berasal dari backfill additive yang sudah disebutkan oleh
migration dan harus mempunyai rekonsiliasi exact. Row-count saja tidak cukup;
identifier dan nilai keuangan/stock juga harus cocok.

## Tahap D — production database rollout

Dilakukan hanya setelah rehearsal PASS dan user memberi instruksi production:

1. umumkan maintenance window dan hentikan mutation POS/Backoffice;
2. pastikan Finance queue tidak aktif dan Offline submission sudah terminal;
3. buat backup baru dan buktikan restore point tersedia;
4. ulangi discovery tepat sebelum rollout dan batalkan bila ledger/data drift;
5. apply delta per checkpoint:
   - A: Sales foundation, feature tetap OFF;
   - B: cutover/compatibility, tanpa menjalankan Apply plan;
   - C: Office fulfillment/Invoice/Finance/discrepancy;
   - D: Purchase foundation/runtime/client read-model, mode tetap MANUAL;
6. jalankan postflight setiap checkpoint dan preservation reconciliation;
7. bila migration gagal, pertahankan transaction rollback dan gunakan
   forward-fix yang diaudit. Jangan melakukan down migration destruktif;
8. buka kembali Retail hanya setelah Retail regression PASS.

## Tahap E — client dan aktivasi bertahap

1. Deploy Backoffice/PWA setelah DB lengkap; jangan sekaligus mengubah mode.
2. Smoke Retail production pada Company yang tetap Retail.
3. Smoke Office dan Purchase dengan Company pilot serta data terkontrol.
4. Aktifkan Office per Company melalui preview/cutover; dokumen menggantung
   mengikuti classifier dan lineage yang sudah dibangun, bukan update massal.
5. Purchase tetap MANUAL. AUTO_RO atau AUTO_PO baru diaktifkan terpisah setelah
   satu siklus manual Receipt/Bill/Payment PASS.
6. Monitor error, queue, stock reconciliation, AR/AP, dan scheduler minimal satu
   siklus bisnis sebelum memperluas Company.

## Stop conditions

Rollout tidak boleh diteruskan jika terdapat ledger/checksum drift, backup belum
teruji, active Finance queue, Offline nonterminal, migration guard gagal,
constraint mismatch, perubahan nilai stock/keuangan tanpa lineage, client/API
version mismatch, atau Retail regression gagal.

## Status evidence

Gunakan label terpisah: `SOURCE READY`, `PRODUCTION DISCOVERY PASS`, `CLONE
REHEARSAL PASS`, `PRODUCTION DATABASE LIVE`, `CLIENT DEPLOYED`, `RETAIL SMOKE
PASS`, `OFFICE/PURCHASE PILOT PASS`, dan `UAT PASS`.

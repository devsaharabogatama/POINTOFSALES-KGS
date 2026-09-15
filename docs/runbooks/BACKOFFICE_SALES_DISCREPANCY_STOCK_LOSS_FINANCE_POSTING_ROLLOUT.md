# Backoffice Sales Discrepancy Stock-Loss Finance Posting — Step 5/6.2

## Clone rehearsal evidence — 2026-09-15

Units 68–69 applied only on `idrufihckscppsyclmsu`. Preflights PASS with expected
absent-rule/enum SETUP; closing postflights eleven and seven PASS respectively.
Thirteen reported rollback-only behavioral scenarios PASS, including canonical
SO/dispatch/LOST resolution, exact FIFO/journal, tenant denial, retry/stale version,
and no extra Stock/Invoice/Payment posting effect. Auth-linked actor and rollback-only
Office preparation corrected; guards remain active during operational calls.
DAMAGED/full-role/concurrency matrix and authenticated UI smoke remain pending.
Production untouched; rollback after installation must use additive forward-fix.


Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED
DEVELOPMENT; AUTHENTICATED SMOKE/UAT PENDING**.

Target hanya project Development terisolasi `fkywtxucmyjvpwdiqpix`.
Production `nbxjslqojexjfogamnjt` dan staging lama `yjxpddwrjdczuqyix`
tidak boleh dipakai untuk rollout ini.

## Outcome dan impact map

- Event `STOCK_LOSS` dari discrepancy Backoffice `LOST`/`DAMAGED` yang sudah
  dibuat `HOLD` oleh resolution Gudang menjadi eligible pada Posting Queue
  Finance existing.
- Journal memakai kontrak Finance existing: debit `STOCK_LOSS_EXPENSE` dan
  kredit `INVENTORY_ASSET` pada Transit Warehouse.
- Untuk Company aktif yang belum memiliki exact mapping `STOCK_LOSS`, migration
  membuatnya dari satu fallback Company yang valid atau satu system account
  yang valid. Migration juga membuat rule set versioned dua baris jika memang
  belum ada rule set. Existing exact mapping tidak ditimpa; mapping ambigu,
  invalid, atau rule set parsial tetap fail closed.
- Posting merekonsiliasi immutable stock effect, exact FIFO allocation,
  Stock Movement, discrepancy line, SO, Company, category, mapping, dan rule.
- Tanggal ekonomi adalah tanggal resolution menurut timezone Company. Jika
  periodenya tertutup, jurnal menjadi prior-period adjustment pada periode
  terbuka berikutnya; tanpa periode postable, posting ditolak.
- Direct impact hanya private dispatcher/support predicate dan posting core
  Finance. Tidak ada public RPC atau UI baru.
- Stock/FIFO sudah final di operasi Gudang dan tidak ditulis ulang oleh Finance.
  Reservation, SO/DO, Invoice, Payment, POS Retail, Cashier Session, template
  dokumen, stock adjustment existing, dan cutover tidak berubah.
- Exact retry mengembalikan Journal yang sama. Stale version, cross-tenant,
  source/cost drift, mapping/rule ambigu, dan period tidak postable ditolak
  transactional.
- Behavioral pertama setelah `135000` membuktikan resolver shortage masih
  memakai enum `ADJUSTMENT` untuk source discrepancy. Constraint canonical
  mencadangkan enum itu khusus `stock_adjustment_documents`, sehingga seluruh
  transaksi test rollback sebelum Stock/Finance effect tersimpan. Forward-fix
  `136000` memberi identity khusus `BACKOFFICE_DISCREPANCY_LOSS`; constraint dan
  flow Stock Adjustment tetap tidak diubah.

## Urutan pemulihan manual saat ini

Base `135000` sudah dijalankan. Jangan jalankan migration itu lagi.

1. [Forward-fix preflight](../../supabase/diagnostics/backoffice_sales_discrepancy_loss_movement_type_fix_preflight.sql)
2. [Forward-fix migration](../../supabase/migrations/20260912136000_backoffice_sales_discrepancy_loss_movement_type_fix.sql)
3. [Behavioral rollback-only Step 5/6.2](../../supabase/tests/backoffice_sales_discrepancy_stock_loss_finance_posting_behavior.sql)
4. [Forward-fix postflight](../../supabase/diagnostics/backoffice_sales_discrepancy_loss_movement_type_fix_postflight.sql)
5. [Base Step 5/6.2 postflight](../../supabase/diagnostics/backoffice_sales_discrepancy_stock_loss_finance_posting_postflight.sql)

Jalankan setiap file secara utuh. Pada preflight, status `SETUP` untuk
`s5_2_posting_rule_provision_contract` berarti rule belum ada dan akan dibuat
oleh migration; itu bukan blocker. Stop pada SQL error, `BLOCKER`, atau `FAIL`.
Migration jangan dijalankan ulang setelah ledger masing-masing tercatat.

## Authenticated smoke setelah seluruh SQL PASS

1. Di Backoffice Development, buat SO lalu Dispatch penuh.
2. Saat penerimaan Customer, catat satu shortage dengan kondisi fisik `LOST`
   atau `DAMAGED`, lalu selesaikan dari Surat Jalan sebagai Admin Gudang.
3. Pastikan Stock/FIFO Transit sudah berkurang tepat sekali dan Event Stock Loss
   masih `HOLD` sebelum proses Finance.
4. Buka Finance → Posting Queue. Event harus tampil dan hanya role Finance yang
   mempunyai permission dapat menjalankan posting sesuai policy Company.
5. Pastikan Event menjadi Posted tepat sekali dan Journal berisi dua baris
   seimbang: debit Beban Selisih Stok dan kredit Persediaan Transit.
6. Pastikan retry tidak membuat Journal/Movement baru; Invoice, Payment,
   Qty To Invoice, Reservation, dan SO/DO tidak berubah karena posting Finance.
7. Uji stale tab, user tanpa akses Finance, ganti Company, dan kedua kondisi
   `LOST` serta `DAMAGED`.

## Rollback / forward-fix

Enum PostgreSQL tidak dihapus pada rollback. Jika `136000` gagal sesudah enum
ditambahkan tetapi sebelum ledger tercatat, jalankan ulang preflight: status
enum `PASS` diperbolehkan dan migration bersifat retry-safe pada penambahan enum.
Setelah ledger tercatat, jangan menghapus enum, wrapper, Event, atau Journal.
Koreksi berikutnya harus forward-only dan menjaga dispatcher chain, immutable
Finance history, serta Stock/FIFO effect yang sudah final.

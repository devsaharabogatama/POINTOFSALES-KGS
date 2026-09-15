# Backoffice Sales Invoice Posting Runtime Rollout

## 2026-09-15 historical-clone regression evidence

Clone `idrufihckscppsyclmsu` regression PASS with 14 reported scenarios after
units 48–51. Fixture now prepares Office mode under transaction-local guarded
setup, clears marker and asserts root-mode authority before operational RPC.
Accepted quantity comes from canonical Dispatch/Customer Receipt, not direct
order-line edits. Invoice-only event/journal baseline is captured after Receipt
COGS. Entire fixture rolls back; runtime gates and installed migrations unchanged.
This is database regression evidence, not Production/client/UI smoke or UAT.

Status: LOCAL READY. Target hanya isolated Development Supabase
`fkywtxucmyjvpwdiqpix`; production dan staging tidak boleh digunakan.

## Outcome dan batas gate

Gate `20260909161000` membuka posting atomik untuk Regular Invoice dan Down
Payment Invoice Backoffice. Nomor final memakai sequence Invoice canonical yang
sama dengan POS, tetapi relation dan runtime Backoffice tetap terpisah.

Kontrak yang ditegakkan server-side:

- hanya role dengan resolved capability `POST` pada permission customizable
  `finance.journals_reports` yang dapat posting. Gate ini menegakkannya secara
  lokal pada Invoice walaupun lifecycle global permission masih `SHADOW`;
- `invoice_date` wajib berada dalam Accounting Period `OPEN` atau `REOPENED`;
- exact retry mengembalikan response lama, sedangkan operation ID dengan payload
  berbeda dan stale `master_version` ditolak;
- Regular Invoice memfinalkan quantity hold menjadi invoiced quantity;
- DP `POSTED` tertua diterapkan otomatis ke Regular Draft dan masih dapat diedit
  sebelum Regular Invoice diposting;
- penerapan DP tidak boleh melebihi sisa DP atau membuat Invoice negatif;
- DPP dan pajak DP disimpan terpisah hingga exact tax rule/version/account;
- posting membuat satu Financial Event dan satu balanced Journal dalam transaksi
  yang sama. Kegagalan Finance me-rollback status Invoice dan quantity/application
  final state.

Journal Down Payment Invoice:

- debit Customer Receivable sebesar tagihan DP;
- credit Customer Advance Liability sebesar DPP DP;
- credit Output Tax per akun pajak snapshot sebesar pajak DP.

Journal Regular Invoice dengan DP:

- debit Customer Receivable sebesar sisa tagihan;
- debit Customer Advance Liability sebesar basis DP yang dipakai;
- debit Output Tax per akun pajak DP sebesar pajak DP yang dipakai;
- credit Sales Revenue sebesar DPP Regular Invoice;
- credit Output Tax per akun pajak Regular Invoice.

Struktur ini mengikuti model dokumen Odoo: DP adalah Invoice tersendiri dan
dikurangkan pada Invoice final. Payment/receipt Customer dan histori pembayaran
belum dibuka oleh gate ini.

## Impact map

- Direct: `backoffice_sales_invoices`, Invoice operations/audit, quantity
  allocations, DP applications, receivable schedules, tax breakdown baru untuk
  aplikasi DP, Financial Event, Journal, serta versioned posting-rule definition.
- Downstream: Finance dispatcher mengenali dua event Backoffice Invoice;
  Payment gate berikutnya dapat mengalokasikan receipt ke schedule `OPEN`.
- Tidak terdampak: POS sales mutation, POS Invoice snapshot, Reservation,
  Dispatch, Customer receipt, Stock On Hand, Transit, FIFO/COGS, dan DO.
- Compatibility: zero existing posted Backoffice Invoice adalah migration guard;
  Draft lama wajib lolos reconciliation sebelum migration. Shared sequence
  mencegah nomor final bertabrakan dengan POS tanpa mengubah nomor POS lama.
- Concurrency/retry: lock per operation, Invoice, dan Sales Order; final effects
  berada dalam satu transaction dan exact retry tidak membuat Event/Journal baru.
- Rollback: SQL error saat migration atau runtime membatalkan satu transaction.
  Setelah sukses, perbaikan memakai forward-fix karena rule/audit sudah versioned.

## Urutan manual

Jalankan satu per satu pada project Development tersebut:

1. `supabase/diagnostics/backoffice_sales_invoice_posting_runtime_preflight.sql`
2. `supabase/migrations/20260909161000_backoffice_sales_invoice_posting_runtime.sql`
3. `supabase/diagnostics/backoffice_sales_invoice_posting_runtime_postflight.sql`
4. `supabase/tests/backoffice_sales_invoice_posting_runtime_behavior.sql`
5. `supabase/diagnostics/backoffice_sales_invoice_posting_runtime_postflight.sql`

Stop bila preflight memiliki `BLOCKER`, postflight memiliki `FAIL`, atau ada SQL
error. Kirim seluruh output. Jangan menjalankan migration dua kali.

Migration ini mengikuti lifecycle posting rule canonical secara eksplisit:
`DRAFT` -> isi rule lines -> audit `CREATE` -> `APPROVED` -> audit `APPROVE`.
Preflight memverifikasi trigger lifecycle aktif dan postflight memastikan tidak
ada Draft residue serta audit Create/Approve lengkap. Jika migration gagal
sebelum `COMMIT`, transaction me-rollback seluruh perubahan termasuk retirement
rule lama dan ledger; ulangi dari preflight setelah memakai file yang diperbaiki.

Preflight juga mewajibkan satu Accounting Period `OPEN/REOPENED` yang menaungi
tanggal behavioral test. Jika `openPeriodsForBehaviorDate=0`, buat/buka periode
Development lewat Finance sebelum menjalankan migration; gate tidak membuat
periode secara otomatis.

## Behavioral coverage

Test rollback-only memakai fixture canonical yang tersedia: active Company,
Store, sale-source Warehouse, Customer, Product/UOM, current open period, dan
exact Output Tax account. Test mencakup:

- taxed SO canonical dan Customer receipt quantity yang sudah diterima;
- stale DP posting ditolak;
- custom permission `TANPA_AKSES` benar-benar memblokir Post Invoice meskipun
  catalog Finance global masih `SHADOW`;
- DP Invoice diposting dengan nomor canonical dan Journal;
- DP tertua auto-fill pada Regular Draft lalu nilainya diedit;
- split basis/pajak serta lineage exact tax account;
- Regular posting memfinalkan quantity dan DP application;
- Journal seimbang dengan debit pajak DP dan credit pajak Invoice;
- exact retry tidak menduplikasi Event/Journal;
- jumlah POS `sales_headers` tidak berubah;
- semua fixture di-rollback.

## Status setelah PASS

Migration + postflight + behavior PASS hanya berarti `DATABASE LIVE` dan
`MANUAL DATABASE TEST PASS` pada isolated Development. Client belum deployed,
authenticated UI smoke belum PASS, UAT belum PASS, dan production belum siap.
Gate berikutnya adalah Payment/receipt allocation dan histori pembayaran per
Invoice, bukan pembuatan Pro-Forma baru untuk setiap pembayaran.

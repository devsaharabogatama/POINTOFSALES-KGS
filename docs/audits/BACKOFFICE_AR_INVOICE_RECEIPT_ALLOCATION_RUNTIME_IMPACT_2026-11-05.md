# Backoffice AR Invoice/Receipt Allocation Runtime Impact — 2026-11-05

## Status dan klasifikasi

- Task: Task 3 dari rekonsiliasi Backoffice AR open-item.
- Klasifikasi calon perubahan: `PRODUCT_BEHAVIOR_CHANGE` dan
  `SCHEMA_OR_MIGRATION_CHANGE`.
- Fase saat ini: Fase A read-only audit; belum ada perubahan runtime/schema/data.
- Task 2 foundation: `DATABASE LIVE`, first/closing postflight `PASS`, rollback
  behavior `PASS`; authenticated client smoke dan UAT belum terbukti.
- Migration `20261105100000` sudah live dan immutable. Task 3 wajib memakai
  forward migration baru.

## Expected business outcome

1. Setiap Backoffice Invoice baru yang Posted menjadi debit open-item AR.
2. Setiap Backoffice Customer Receipt yang Posted menjadi credit open-item AR.
3. Allocation yang dipilih Finance tetap menjadi sumber instruksi manual dan
   dicatat atomik pada open-item ledger saat Receipt diposting.
4. Partial/full allocation didukung. Sisa Receipt tetap sebagai customer-scoped
   AR open credit dan dapat dialokasikan Finance ke Invoice customer yang sama.
5. Posting uang tetap satu kali: Debit Cash/Bank, Credit AR. Open-item allocation
   adalah subledger dan tidak membuat jurnal kedua.
6. Exact retry harus idempotent; changed retry, stale version, cross-Company,
   cross-Customer, dan over-allocation harus ditolak.
7. POS Retail, Stock/Reservation/FIFO/HPP, Backoffice dispatch/Return, dan
   Customer Balance tidak berubah. Customer Balance hanya melalui aksi eksplisit
   pada task terpisah.

Source of truth bisnis: keputusan user pada audit induk
`BACKOFFICE_AR_OPEN_ITEM_CREDIT_RECONCILIATION_IMPACT_2026-11-03.md`.

## Active call chain yang terbukti dari repository

### Client

- `backoffice/src/components/CustomerReceiptView.tsx` mengumpulkan alokasi
  Invoice, metode pembayaran, jumlah diterima, dan disposition.
- `backoffice/src/app/api/finance/customer-receipts/route.ts`:
  - GET -> `get_finance_customer_receipts()`;
  - SAVE_DRAFT normal -> `save_customer_receipt_allocated_draft(...)`;
  - SAVE_DRAFT advance -> `save_customer_receipt_draft_with_disposition(...)`;
  - POST -> `post_customer_receipt_unified(...)`.
- Belum ada caller client/API untuk `get_finance_ar_open_items(...)`. SQL claim
  impersonation pada behavior Task 2 bukan authenticated client smoke.

### Receipt runtime

- Defining migration:
  `20260911160000_backoffice_sales_payment_collection_runtime.sql`.
- `save_customer_receipt_allocated_draft(...)` menerima source
  `RETAIL_SALE`/`BACKOFFICE_SALES_INVOICE`, menulis legacy allocation, lalu
  mensyaratkan `received_amount = sum(allocation)`.
- `post_customer_receipt_allocated(...)` mengunci Receipt/Invoice, memeriksa
  outstanding ulang, memanggil canonical `post_customer_receipt(...)`, lalu
  merekonsiliasi schedule Invoice.
- `20260911163000_backoffice_sales_ar_reporting_integration.sql` membentuk
  `post_customer_receipt_unified(...)`: disposition `CUSTOMER_BALANCE` tetap ke
  jalur advance; selain itu ke allocated post.
- Finance event yang aktif tetap satu Debit Cash/Bank dan satu Credit AR.

### Invoice runtime

- Defining function:
  `20260909161000_backoffice_sales_invoice_posting_runtime.sql` melalui
  `post_backoffice_sales_invoice(uuid,bigint,uuid)`.
- Finance posting dibentuk oleh
  `private.post_backoffice_sales_invoice_financial_event_core(...)` dan telah
  dipatch oleh migration kompatibilitas berikutnya. Exact live definition/digest
  wajib diinventaris sebelum forward migration Task 3.

### Open-item foundation

- Defining migration: `20261105100000_backoffice_ar_open_item_foundation.sql`.
- `ar_open_item_registry` append-only saat ini menerima Invoice, Receipt,
  Credit Note, dan Price Correction.
- `ar_open_item_operations.operation_kind` saat ini hanya menerima operation
  backfill.
- Allocation validator saat ini hanya memasangkan source kind dengan operation
  backfill; belum ada operation runtime.
- Backfill Receipt hanya mengambil slice allocation Backoffice dari Receipt
  campuran; ini wajib dipertahankan untuk compatibility data lama.

## Identifier source map

| Identifier | Defining source |
|---|---|
| `backoffice_sales_invoices` | `20260909156000_backoffice_sales_invoice_accounting_foundation.sql` |
| `post_backoffice_sales_invoice(uuid,bigint,uuid)` | `20260909161000_backoffice_sales_invoice_posting_runtime.sql` |
| `customer_receipt_documents` | `20260827100000_finance_customer_receipt_ar_foundation.sql` |
| `save_customer_receipt_allocated_draft(...)` | `20260911160000_backoffice_sales_payment_collection_runtime.sql` |
| `post_customer_receipt_allocated(...)` | `20260911160000_backoffice_sales_payment_collection_runtime.sql` |
| `post_customer_receipt_unified(...)` | `20260911163000_backoffice_sales_ar_reporting_integration.sql` |
| `ar_open_item_*` | `20261105100000_backoffice_ar_open_item_foundation.sql` |
| `get_finance_ar_open_items(uuid,boolean)` | `20261105100000_backoffice_ar_open_item_foundation.sql` |

## State dan hole yang memengaruhi desain

### Proven

- Foundation Task 2 live dan konsisten dari postflight/behavior/closing
  postflight yang diberikan user.
- Existing Receipt allocation hanya mengenal allocation penuh atau disposition
  Customer Balance penuh.
- Existing open-item constraints belum menerima operation runtime.
- Existing Backoffice/PWA tidak memanggil read RPC open-item baru.

### BELUM TERBUKTI

1. Exact live definition/digest untuk Invoice post, Receipt save/post, dan
   open-item validator setelah seluruh forward migration.
2. Populasi Draft Receipt saat cutover yang mempunyai allocation campuran atau
   berpotensi berubah semantics.
3. Jumlah Invoice/Receipt Posted setelah waktu instalasi Task 2 yang belum masuk
   registry; ini adalah cutover delta yang harus dibackfill tepat sekali.
4. Active permission/capability untuk endpoint read open-item melalui client.
5. Read-only API/client consumer Task 3 telah disetujui user pada 2026-11-05;
   exact placement dan response contract tetap harus mengikuti workspace
   Penerimaan Customer yang aktif.

## Impact map

### Direct impact

- Invoice post: register debit AR open-item setelah canonical journal Posted.
- Receipt post: register Backoffice credit slice, operations, dan allocations
  setelah canonical journal Posted.
- Receipt Draft: memungkinkan `received_amount >= allocated_amount`; residual
  menjadi open credit, bukan Customer Balance otomatis.
- Constraint/validator open-item: menambah runtime operation kind tanpa
  melemahkan backfill/immutability.

### Downstream impact

- Invoice outstanding/schedule dan existing receipt reports tetap dibaca untuk
  compatibility sampai report cutover Task 7.
- Finance Event/Journal tidak boleh berubah jumlah maupun account routing.
- Audit harus merekam registry, operation, allocation, actor, request hash,
  source version, dan exact idempotency lineage.

### Explicitly preserved

- POS Retail dan POS Customer Receipt.
- Backoffice Sales Order, dispatch, Return, Credit Note, refund.
- Stock, reservation, FIFO/HPP.
- Existing Posted documents/journals dan allocation history.
- Explicit Customer Balance advance flow.

## Concurrency, retry, dan rollback

- Lock order: Company/advisory key -> source Receipt -> target Invoice items ->
  Receipt credit item, dengan deterministic UUID ordering untuk multi-Invoice.
- Exact idempotency replay mengembalikan hasil sama tanpa row/journal baru.
- Idempotency key sama dengan payload/hash berbeda harus gagal.
- Stale Receipt/Invoice version dan residual berubah harus gagal sebelum post.
- Kegagalan register/allocation open-item harus me-roll back canonical Receipt
  post dalam transaksi yang sama; dilarang ada journal tanpa subledger baru.
- Rollback schema tidak menghapus history live; koreksi setelah live harus
  forward-fix.

## Regression matrix minimum

- Invoice baru unpaid, partial paid, fully paid.
- Receipt equal, partial, multi-Invoice, dan overpayment residual open credit.
- Cash/Bank/Transfer aktif; mixed Retail/Backoffice Receipt compatibility.
- Same/cross Company dan same/different Customer.
- Exact retry, changed retry, duplicate, stale version, concurrent allocation.
- Open/locked accounting period dan controlled/automatic Finance posting.
- Historical allocation vs transaksi baru setelah cutover.
- POS Retail regression; Backoffice Return/Credit Note tetap tidak berubah.

## Planned Phase B files — belum diotorisasi sampai gate lulus

- Forward migration baru setelah exact state inventory.
- SELECT-only preflight dan postflight.
- Rollback-only behavior test.
- Minimal read-only Backoffice API consumer bila disetujui untuk authenticated
  client smoke.
- Handoff, manifest, runbook, dan root README status.

## Keputusan user sebelum implementasi

1. Receipt Rp10 juta dengan allocation Rp7 juta harus Posted satu
   kali, Debit Cash/Bank Rp10 juta, Credit AR Rp10 juta; Rp7 juta menutup Invoice
   dan Rp3 juta tetap open credit customer yang sama. Ini mengikuti target
   open-item audit induk; belum diimplementasikan.
2. Finance tetap memilih allocation manual dari UI; sistem tidak otomatis
   memilih Invoice tertua, sesuai keputusan user sebelumnya.
3. User menyetujui endpoint dan panel read-only minimal pada Task 3 supaya
   authenticated smoke dapat dijalankan langsung dari aplikasi. UI allocation
   lengkap, Apply Credit Note, Refund, dan conversion tetap Task 5/7.

Keputusan bisnis sudah cukup. Exact production state masih wajib dibuktikan
melalui `supabase/diagnostics/backoffice_ar_invoice_receipt_allocation_preflight.sql`;
sebelum itu `Active call chain` belum boleh diberi status final `PROVEN` untuk
Fase B.

## Fase A closure dan Fase B local evidence

User mengembalikan seluruh output preflight production pada 2026-11-05.
State terbukti `FOUNDATION_INSTALLED_TASK3_NOT_INSTALLED`; seluruh dependency,
exact active digest, cutover delta, Draft compatibility, privilege boundary,
dan idle runtime boundary berstatus `PASS`. Dengan bukti itu:

- active call chain Fase B: **PROVEN**;
- design-changing unknown: **NONE**;
- Task 2 migration `20261105100000`: immutable dan tidak diubah;
- migration Task 3 baru: `20261105110000`.

Audit dependency OID menemukan bahwa memindahkan function lalu membuat wrapper
tidak otomatis mengalihkan caller PL/pgSQL yang sudah ter-compile. Karena itu
`register_backoffice_sales_invoice_payment(...)` dibuat ulang setelah wrapper
Receipt terbentuk. Ini memastikan entry point detail Invoice dan Finance
workspace sama-sama mendaftarkan open-item.

Local evidence package:

- PostgreSQL parser PASS untuk migration/preflight/postflight/behavior;
- scoped ESLint dan TypeScript PASS;
- Next.js production build PASS;
- focused contract test 3/3 PASS;
- full database behavior, authenticated smoke, client deploy, dan UAT belum
  dilakukan dan tidak diklaim.

## Correction audit setelah first execution error 42601

Eksekusi pertama candidate migration gagal sebelum commit dengan PostgreSQL
`42601: record variable cannot be part of multiple-item INTO list`. Repeated
SELECT-only production preflight kemudian membuktikan state tetap
`FOUNDATION_INSTALLED_TASK3_NOT_INSTALLED`, ledger Task 3 tidak ada, seluruh
active runtime digest tetap sama, cutover delta nol, Draft Receipt nol, dan
Finance/Offline runtime boundary idle. Dengan demikian candidate belum pernah
live dan koreksi in-place pada version `20261105110000` diperbolehkan; migration
Task 2 `20261105100000` tetap immutable.

Impact tracing menemukan tepat dua occurrence invalid pada candidate:

1. `private.ar3_register_backoffice_invoice_open_item(...)` memilih canonical
   Posted AR Journal dan Journal Line;
2. `private.ar3_register_backoffice_receipt_open_item(...)` memilih canonical
   Posted AR Journal dan Journal Line.

Keduanya menggunakan `SELECT journal,line INTO STRICT v_journal,v_line`, lalu
hanya membaca `.id` dari kedua composite row. Tidak ada caller atau downstream
consumer yang memerlukan composite snapshot tersebut. Koreksi paling sempit
adalah memilih `journal.id,line.id` ke dua scalar `uuid`, mempertahankan
`INTO STRICT`, predicate Company/Event/Account/Customer/Debit/Credit, dan
pre-check `count(*) = 1` tanpa perubahan.

### Correction impact map

- Direct impact: hanya kompilasi dua helper registrasi open-item Task 3.
- Downstream preserved: Invoice/Receipt wrapper, canonical Journal, operation,
  allocation, residual customer-scoped open credit, audit dan read RPC.
- Explicitly unchanged: POS Retail, Backoffice Return/Credit Note, payment
  amount, Customer Balance, Stock/Reservation/FIFO/HPP, historical data dan
  semua Company lain.
- Compatibility: tidak ada data Task 3 yang perlu backfill/repair karena
  candidate ter-rollback penuh dan ledger absent.
- Concurrency/idempotency/retry: lock, unique identity, `INTO STRICT`, request
  hash dan stale-version guard tidak berubah.
- Rollback/forward-fix: bila corrected candidate gagal sebelum ledger, hentikan
  dan ulangi state proof; setelah ledger live, koreksi berikutnya wajib memakai
  forward migration baru.

### Correction validation matrix

- compile bentuk PL/pgSQL scalar multi-target `INTO STRICT` secara executable;
- parse file migration utuh dan pastikan tidak ada composite multi-item `INTO`;
- jalankan scoped lint, TypeScript, build dan focused contract tanpa
  memperlemah assertion;
- production order tetap migration -> postflight -> rollback-only behavior ->
  closing postflight;
- authenticated client smoke/UAT tetap terpisah dan belum boleh diklaim.

Design-changing unknown: **NONE**. Error diklasifikasikan **PRODUCT FIX** pada
candidate schema migration yang belum pernah live, bukan fixture/test harness
atau perubahan precondition.

## Production database closure

Corrected migration kemudian berhasil dipasang. First postflight, rollback-only
behavior, dan closing postflight seluruhnya PASS. Evidence production:

- ledger Task 3 tepat satu dan seluruh wrapper/registration runtime aktif;
- registry exact: 535 source/registry Invoice dan 313 source/registry Receipt;
- allocation exact: 380 source/open-item allocation, zero mismatch dan zero
  over-allocation;
- behavior membuktikan authenticated Backoffice Finance actor, partial Invoice
  allocation plus customer-scoped residual open credit, satu full
  Cash/Bank-to-AR Journal, append-only registration, residual read visibility,
  exact retry, changed retry denial, Invoice-detail payment wrapper binding,
  zero Retail/Stock/FIFO effect, dan seluruh test write rolled back;
- closing postflight membuktikan behavior tidak meninggalkan perubahan.

Status akhir database: `DATABASE LIVE` YES. Status client: `CLIENT DEPLOYED` NO,
`SMOKE PASS` NO, `UAT PASS` NO.

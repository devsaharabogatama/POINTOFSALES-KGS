# Backoffice AR Open-Item Credit Reconciliation Impact Audit

**Tanggal:** 2026-11-03  
**Klasifikasi:** Fase A `READ_ONLY_AUDIT` untuk calon
`SCHEMA_OR_MIGRATION_CHANGE` + `PRODUCT_BEHAVIOR_CHANGE`  
**Status:** desain belum disahkan; tidak ada perubahan runtime/database/client

## 1. Tujuan bisnis

Flow Backoffice Sales Return perlu mendukung pola open-item seperti Odoo:

1. Return fisik dan koreksi komersial tetap dua efek yang dapat ditelusuri.
2. Credit Note membentuk kredit pada akun Piutang Customer.
3. Kredit tersebut dapat dialokasikan sebagian/penuh ke Invoice sumber atau
   Invoice Customer lain, dikembalikan melalui Kas/Bank, atau—bila dipilih
   eksplisit—dikonversi menjadi Customer Balance.
4. Invoice pengganti dapat dibuat sebagai Draft tanpa menghapus Invoice,
   Credit Note, Payment, Return, Stock Movement, FIFO, atau Journal lama.
5. Semua alokasi harus tenant-scoped, customer-scoped, append-only,
   transactional, idempotent, concurrency-safe, period-aware, dan audited.

Referensi pembanding resmi:

- Odoo 19 Credit Notes and Refunds:
  <https://www.odoo.com/documentation/19.0/applications/finance/accounting/customer_invoices/credit_notes.html>
- Odoo 19 Payments / outstanding credits:
  <https://www.odoo.com/documentation/19.0/applications/finance/accounting/payments/online.html>
- Odoo 19 Bank Reconciliation:
  <https://www.odoo.com/documentation/19.0/applications/finance/accounting/bank/reconciliation.html>
- Odoo 19 Inventory Valuation for returns:
  <https://www.odoo.com/documentation/19.0/applications/inventory_and_mrp/inventory/inventory_valuation/operations_valuation.html>

## 2. Runtime aktif yang terbukti dari repository

### 2.1 Credit Note sekarang memecah nilai ke AR dan Refund Liability

`private.post_backoffice_sales_credit_note_before_retained(...)` menghitung:

- outstanding Invoice = nilai efektif - pembayaran - Credit Note terdahulu;
- `v_ar = least(Credit Note, outstanding)`;
- `v_refund = Credit Note - v_ar`.

Sumber:
`supabase/migrations/20261006140000_backoffice_unified_posted_invoice_revision.sql:2090-2106`.

Jurnal aktif:

- Debit `SALES_RETURN_DISCOUNT`, pembalik pajak, dan/atau koreksi ongkir;
- Kredit `CUSTOMER_RECEIVABLE` hanya sebesar `v_ar`;
- Kredit `CUSTOMER_REFUND_LIABILITY` sebesar `v_refund`.

Sumber: file yang sama, baris `2153-2202`.

### 2.2 Refund sekarang hanya melunasi Refund Liability

`public.post_backoffice_sales_customer_refund(...)` hanya menerima Credit Note
POSTED dengan `refund_liability_amount > 0`, mengunci row Credit Note, membatasi
refund kumulatif, lalu menjurnal:

- Debit `CUSTOMER_REFUND_LIABILITY`;
- Kredit akun Kas/Bank dari Payment Method.

Sumber:
`supabase/migrations/20260917150000_backoffice_sales_customer_refund.sql:346-505`.

### 2.3 Customer Balance sekarang hanya berasal dari receipt advance

Customer Balance credit aktif mensyaratkan Customer Receipt tanpa allocation;
runtime menolak receipt teralokasi dengan
`CUSTOMER_RECEIPT_ADVANCE_MUST_BE_UNALLOCATED`, menambah
`customer_balance_ledger_entries`, lalu memperbarui `customers.current_balance`.

Sumber:
`supabase/migrations/20260827120000_finance_historical_collection_customer_advance.sql:320-392`.

Credit Note belum mempunyai jalur aktif ke Customer Balance.

### 2.4 Reconciliation yang ada bukan open-item AR settlement

`finance_reconciliation_documents` hanya menerima tipe
`STOCK_FIFO_GL`, `SUPPLIER_AP_GL`, `CUSTOMER_BALANCE_GL`, dan `CASH_BANK_GL`.
Allocation-nya membandingkan nilai subledger dengan ledger untuk dokumen
rekonsiliasi laporan; ini bukan many-to-many settlement Invoice/Payment/Credit
Note dengan residual.

Sumber:
`supabase/migrations/20260810230000_g6_phase6c_statements_pending_reconciliation.sql:37-155`.

`finance_journal_lines` sudah tenant/account/customer-scoped, tetapi belum
menyimpan residual atau link partial reconciliation.

Sumber:
`supabase/migrations/20260810180000_g6_phase2_tenant_safe_journal_foundation.sql:290-338`.

### 2.5 UI aktif mengunci user ke model liability

`backoffice/src/components/BackofficeSalesReturnView.tsx` menampilkan
`Pengurang piutang`, `Kewajiban refund`, dan hanya menawarkan `Post Refund`
terhadap sisa liability. UI ini belum menawarkan apply credit ke Invoice,
partial allocation, atau create replacement Draft.

## 3. Gap terhadap target

1. Credit Note yang melebihi outstanding Invoice dipindah otomatis ke Refund
   Liability, sehingga kredit tidak lagi menjadi open AR item.
2. Tidak ada model residual dan partial many-to-many allocation antar
   Invoice, Payment/Receipt, Credit Note, serta refund.
3. Refund hanya dapat dibayar dari Refund Liability, bukan dari open AR credit.
4. Customer Balance dan AR credit bercampur secara konsep bila konversi tidak
   dibuat sebagai tindakan eksplisit.
5. Tidak ada operasi `Reverse and Create Invoice` yang atomik dan audited.
6. Data lama yang sudah masuk Refund Liability memerlukan forward
   reclassification; posted journal tidak boleh ditulis ulang.
7. Return RECEIVED tanpa Credit Note masih dapat meninggalkan revenue/AR tanpa
   koreksi komersial. Backlog ini harus dipisahkan dari implementasi runtime
   baru.

## 4. Target accounting flow

### 4.1 Invoice dan Payment

- Invoice: Debit AR; Kredit Revenue/Tax.
- Payment: Debit Cash/Bank/Clearing; Kredit AR.
- Payment line dialokasikan ke Invoice line secara partial/full. Residual tetap
  open sampai alokasi berikutnya.

### 4.2 Return dan Credit Note

- Return RESTOCK: Debit Inventory; Kredit COGS menurut original FIFO lineage.
- Return DESTROY/non-sellable: tidak menambah sellable stock; mapping kerugian
  final masih memerlukan keputusan Finance.
- Credit Note: Debit Sales Return/Discount, pembalik Tax/Delivery bila berlaku;
  Kredit AR sebesar seluruh nilai Credit Note.
- Credit Note credit dapat direkonsiliasi ke Invoice sumber atau Invoice lain
  milik Customer dan Company yang sama.

### 4.3 Refund dan Customer Balance

- Refund Kas/Bank: Debit AR; Kredit Cash/Bank, kemudian reconcile refund debit
  dengan Credit Note credit.
- Konversi ke Customer Balance, bila dipilih: Debit AR; Kredit Customer Balance
  Liability, kemudian reconcile debit AR dengan Credit Note credit.
- Tidak boleh ada konversi otomatis ke Customer Balance hanya karena Invoice
  sumber sudah lunas.

### 4.4 Replacement Invoice

Operasi opsional `Reverse and Create Invoice`:

1. post Credit Note;
2. alokasikan ke residual Invoice sumber;
3. buat salinan Invoice pengganti berstatus Draft;
4. simpan lineage Return -> Credit Note -> Invoice sumber -> replacement Draft;
5. tidak otomatis mem-post replacement Invoice.

## 5. Urutan task implementasi

### Task 1 — Design closure dan production state inventory

Klasifikasi: `READ_ONLY_AUDIT`.

- Kunci keputusan bisnis pada bagian 8.
- Buat SELECT-only inventory ledger/object/data untuk KMS, LSM, SMS.
- Pisahkan current runtime, open-item candidate, legacy refund liability, Return
  RECEIVED tanpa Credit Note, dan posted refund final.
- Output: state `NOT_INSTALLED`, `INSTALLED_CONSISTENT`,
  `PARTIAL/INCONSISTENT`, atau `UNKNOWN` untuk calon migration.

### Task 2 — AR open-item foundation

Klasifikasi: `SCHEMA_OR_MIGRATION_CHANGE`.

- Tambah model append-only untuk open-item allocation, residual, operation
  idempotency, dan audit. Nama identifier final belum boleh ditetapkan sebelum
  collision/schema inventory Task 1 selesai.
- Backfill hanya membentuk open-item snapshot/link; tidak mengubah posted
  journal.
- Tambah read RPC untuk outstanding Invoice/Credit/Payment.
- Tidak mengubah Return, Stock/FIFO, POS, atau Customer Balance.

### Task 3 — Invoice/Payment allocation runtime

Klasifikasi: `PRODUCT_BEHAVIOR_CHANGE` + bila perlu migration baru.

- Hubungkan Backoffice Customer Receipt/Payment ke open-item allocation.
- Dukung partial/full allocation, residual, exact retry, stale version,
  concurrency lock, same-Customer/same-Company guard.
- Historical allocation tetap dibaca kompatibel.

### Task 4 — Credit Note menjadi AR credit

Klasifikasi: `PRODUCT_BEHAVIOR_CHANGE` + forward migration.

- Ganti split otomatis AR/Refund Liability untuk transaksi baru: seluruh Credit
  Note mengkredit AR.
- Pertahankan reversal revenue/tax/delivery dan Finance posting policy.
- Hubungkan Credit Note ke source Invoice/Return sebagai open credit item.
- Backoffice saja; POS Retail tidak berubah.

### Task 5 — Apply credit, cash refund, dan optional Customer Balance

Klasifikasi: `PRODUCT_BEHAVIOR_CHANGE`.

- Apply Credit Note ke satu/beberapa Invoice.
- Refund partial/full dari open AR credit melalui Cash/Bank.
- Konversi eksplisit ke Customer Balance bila disetujui.
- Maker/checker, permission, period, audit, retry, dan reversal tetap enforced.

### Task 6 — Reverse and Create Invoice

Klasifikasi: `PRODUCT_BEHAVIOR_CHANGE`.

- Aksi atomik untuk post Credit Note + reconcile source residual + create
  replacement Invoice Draft.
- Tidak mengubah dispatch/stock dan tidak auto-post replacement.

### Task 7 — UI Finance dan report

Klasifikasi: `PRODUCT_BEHAVIOR_CHANGE`.

- Credit Note menampilkan original amount, allocated, residual, available
  credit, dan allocation history.
- Tindakan: Apply to Invoice, Refund, Convert to Balance, dan Reverse/Create
  Draft sesuai capability.
- Update Customer Statement, Invoice payment context, AR Aging, dan audit view.

### Task 8 — Legacy/backlog forward correction

Klasifikasi: `SCHEMA_OR_MIGRATION_CHANGE`; dieksekusi setelah runtime baru
terbukti.

- Refund Liability yang belum dibayar: reclass forward Debit Refund Liability /
  Kredit AR open credit.
- Posted refund final tetap legacy-closed.
- Return RECEIVED tanpa Credit Note: batch hanya setelah source Invoice, Return,
  Stock/FIFO, account mapping, dan period dibuktikan per row.
- Tidak menghapus ledger atau menulis ulang posted journal.

### Task 9 — Deployment gates dan UAT

- Preflight read-only -> guarded forward migration -> rollback-only behavior ->
  postflight read-only -> deploy client -> authenticated smoke -> user UAT.
- Status dilaporkan terpisah: `AUDIT COMPLETE`, `LOCAL READY`, `DATABASE LIVE`,
  `CLIENT DEPLOYED`, `SMOKE PASS`, `UAT PASS`.

## 6. Impact map

### Direct impact

- Credit Note posting dan journal ownership.
- Customer Receipt/Payment allocation.
- Customer refund posting/reversal.
- Invoice outstanding/payment status.
- Customer Statement dan AR Aging.
- Backoffice Return/Credit Note/Refund UI.

### Downstream impact

- Finance Event/queue/Journal, accounting period, COA resolver, audit.
- Customer Balance hanya bila explicit conversion disetujui.
- Legacy Refund Liability and existing refund history.
- Replacement Invoice lineage and duplicate prevention.

### Explicitly preserved

- POS Retail, cashier session, POS payment verification, split payment POS.
- Sales Order, dispatch, delivery, reservation.
- Stock Movement, FIFO/HPP, Return warehouse disposition.
- Posted Invoice/Payment/Journal immutability.
- Company isolation and Backoffice permission model.

## 7. Regression matrix wajib

- Invoice unpaid, partial paid, fully paid, overpaid.
- Credit Note smaller/equal/greater than Invoice residual.
- Apply to one/multiple Invoice; credit smaller/equal/greater than target.
- Partial refund, full refund, mixed apply + refund, optional balance conversion.
- Return partial/full, RESTOCK/DESTROY, tax, discount, delivery fee.
- Customer Receipt Cash/Bank/Transfer, pending/posted/reversed where supported.
- Open/locked period and prior-period adjustment.
- Same/cross Company, same/different Customer.
- Exact retry, changed retry payload, duplicate request, stale version,
  concurrent allocation, rollback after downstream failure.
- Legacy Credit Note with AR reduction, Refund Liability unpaid/paid/reversed.
- POS Retail and Backoffice paths both regression-tested; POS must remain
  behaviorally unchanged.

## 8. Keputusan user dan hole tersisa

Keputusan user 2026-11-03:

1. Kelebihan Credit Note default menjadi `AR open credit`; Customer Balance
   hanya melalui aksi eksplisit.
2. Dua aksi disediakan: `Post Credit Note` dan `Post Credit Note & Buat Invoice
   Pengganti`.
3. Replacement Draft menyalin Invoice lama sepenuhnya, tetap Draft, lalu user
   mengeditnya. Tidak ada jurnal sebelum replacement diposting.
4. Account presentation mempertahankan `SALES_RETURN_DISCOUNT` existing.
5. Return `DESTROY`/non-sellable dipisahkan sampai mapping kerugian diputuskan
   Finance.
6. Rollout Company dengan Tax aktif ditahan sampai treatment pajak/e-Faktur
   dikonfirmasi Finance/Tax.
7. Return yang sudah diterima fisik tetapi belum mempunyai Credit Note tetap
   menunggu Finance memilih alokasi Invoice secara manual. Sistem tidak boleh
   memilih Invoice atau membuat Credit Note otomatis.

Hole tersisa:

- Satu Return Backoffice LSM, `RTN-20261021-0000000033`, sudah `RECEIVED`
  tetapi belum dialokasikan menjadi Draft/Posted/Reversed Credit Note. Call
  chain aktif membuktikan penerimaan fisik dan alokasi Finance adalah dua aksi
  terpisah melalui `allocate_backoffice_sales_return_invoices`. User memutuskan
  pada 2026-11-05 bahwa row ini tetap menjadi pekerjaan Finance manual, bukan
  data rusak, auto-allocation, atau kandidat auto-post.
- Inventory mapping yang diterima hanya membawa source/function/account dan
  rentang efektif. Ia belum membawa transaction-category identity yang dipakai
  resolver. Detail ini tidak menghalangi foundation append-only Task 2, tetapi
  wajib dibuktikan sebelum Task 4 mengubah posting Credit Note.
- Treatment Tax/e-Faktur dan akun kerugian `DESTROY` tetap ditahan sesuai
  keputusan user; keduanya tidak boleh diselesaikan melalui asumsi.

## 9. State dan batas bukti saat ini

- Active repository call chain: `PROVEN` dari migration dan UI yang disebutkan.
- Production runtime lama: `INSTALLED_CONSISTENT` untuk dependency ledger,
  runtime object, posted journal lineage, accounting period, dan queue yang
  diperiksa. Bukti ini tidak menyatakan seluruh fitur UAT PASS.
- Production capability calon open-item foundation: `NOT_INSTALLED`; catalog
  inventory tidak menemukan candidate object. Exact identifier/version baru
  tetap harus dikunci dan dipreflight sebelum Fase B Task 2.
- Production data KMS/LSM/SMS yang diterima pada 2026-11-05:
  - `366` Posted Invoice terinventarisasi: KMS `121`, LSM `190`, SMS `55`;
  - satu Invoice LSM `INV-20261008-0000000636` bernilai Rp3.200.000 mempunyai
    Receipt Posted Rp1.440.000 dan Credit Note AR reduction Rp1.760.000;
  - satu native Backoffice Credit Note LSM Posted bernilai Rp1.760.000 dan
    seluruhnya mengurangi AR;
  - Refund Liability Rp2.720.000 berasal dari dua Credit Note
    `RETAINED_RETAIL`, sehingga berada di luar native Backoffice conversion
    Task 8;
  - native Backoffice legacy Refund Liability residual yang terjaring inventory
    berjumlah nol. Ini bukan bukti bahwa tidak ada liability pada flow Retail;
  - satu Return Backoffice LSM `RECEIVED` belum mempunyai Credit Note seperti
    dijelaskan pada bagian hole;
  - posted journal lineage missing `0`, active Finance queue `0`, dan Customer
    Balance terdampak `0` pada scope audit ini.
- Task 1: `AUDIT COMPLETE` untuk inventory yang dirancang. Task 2 belum
  `LOCAL READY`; Fase A Task 2 harus menetapkan identifier, invariant/backfill,
  privilege, dan regression matrix sebelum SOP Gate implementasi.
- Tidak ada source code, schema, fixture, assertion, atau production data yang
  diubah oleh artefak ini.


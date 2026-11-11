# Backoffice AR Credit Note Open-Credit Impact Audit

**Tanggal:** 2026-11-05  
**Task:** Task 4 dari Backoffice AR open-item roadmap  
**Klasifikasi:** `PRODUCT_BEHAVIOR_CHANGE` + `SCHEMA_OR_MIGRATION_CHANGE`  
**Status:** Fase A/B dan database rollout selesai. Migration, first postflight,
tiga rollback-only behavior, dan closing postflight PASS. Authenticated smoke
dan UAT belum dilakukan; Task 5 manual apply/refund/convert tetap terpisah.

## 1. Expected business outcome

Untuk Company dengan `BACKOFFICE_DELIVERED_QTY_INVOICE`:

1. Credit Note native Backoffice baru mengkredit `CUSTOMER_RECEIVABLE` sebesar
   seluruh `grand_total`.
2. Nilai tersebut menjadi AR open credit milik Customer dan Company yang sama.
3. Posting tidak otomatis mengalokasikan kredit ke Invoice sumber/Invoice lain,
   Customer Balance, atau Cash/Bank refund.
4. Finance menentukan penggunaan kredit secara manual pada Task 5.
5. Revenue return/discount, Tax reversal, delivery correction, accounting
   period, Finance Event/Journal, idempotency, audit, dan lineage dipertahankan.
6. `RETAINED_RETAIL` dan seluruh POS Retail tidak berubah.

Source of truth keputusan bisnis ada pada
`docs/audits/BACKOFFICE_AR_OPEN_ITEM_CREDIT_RECONCILIATION_IMPACT_2026-11-03.md`
bagian 4, 5 Task 4, dan 8.

## 2. Active execution path yang terbukti

### 2.1 UI dan API

- `backoffice/src/components/BackofficeSalesReturnView.tsx` memanggil endpoint
  Post Credit Note dan menampilkan `arReductionAmount` serta
  `refundLiabilityAmount`.
- `backoffice/src/app/api/finance/backoffice-credit-notes/[id]/post/route.ts`
  memanggil `public.post_backoffice_sales_credit_note(uuid,bigint,uuid)`.

### 2.2 Runtime dispatcher dan native core

`public.post_backoffice_sales_credit_note(...)` pada
`supabase/migrations/20260918150000_retained_retail_credit_note_refund_bridge.sql:757-772`
memisahkan `RETAINED_RETAIL` dari native Backoffice. Task 4 hanya boleh
mengubah cabang native.

Definisi native aktif terakhir berada pada
`supabase/migrations/20261006140000_backoffice_unified_posted_invoice_revision.sql:2030-2245`.
Runtime mengunci Company/operation/Credit Note/Invoice, memvalidasi permission,
retry, version, tanggal, source Invoice, periode dan mapping. Saat ini ia
membagi `grand_total` menjadi `v_ar` sebesar sisa Invoice dan `v_refund` untuk
kelebihan, lalu mengkredit AR dan Refund Liability.

Target Task 4: `v_ar = grand_total`, `v_refund = 0`, kemudian mendaftarkan satu
open credit tanpa membuat allocation.

### 2.3 Open-item foundation dan Task 3

- `ar_open_item_registry` mendukung `CREDIT_NOTE` berarah `CREDIT` dan exact AR
  Journal line.
- `ar_open_item_allocations` append-only menghubungkan debit dan credit item.
- Task 2 membackfill native Credit Note lama dan mengalokasikannya penuh ke
  source Invoice agar behavior historis tetap sama.
- Task 3 menambah runtime `POST_RECEIPT`; belum ada registrasi Credit Note baru
  dan belum ada operasi manual apply-credit.

Sumber:

- `supabase/migrations/20261105100000_backoffice_ar_open_item_foundation.sql`;
- `supabase/migrations/20261105110000_backoffice_ar_invoice_receipt_allocation_runtime.sql`.

## 3. Consumer impact map

### 3.1 Direct impact

1. `private.post_backoffice_sales_credit_note_before_retained(...)`: full AR
   credit, zero new Refund Liability, one immutable Registry item, zero
   allocation.
2. Native Credit Note Event amount snapshot dan Journal line.
3. Return native baru tidak menjadi `REFUND_PENDING` hanya karena source
   Invoice sudah lunas.

### 3.2 Invoice consumers yang wajib berbasis allocation

Consumer berikut sekarang otomatis mengurangi source Invoice dari raw/source
Credit Note. Semuanya harus membaca jumlah allocation `CREDIT_NOTE -> INVOICE`:

1. `private.backoffice_invoice_receivable_before_receipts(...)` dari
   `20260928110000_backoffice_posted_invoice_price_correction.sql:362-372`.
2. `private.reconcile_backoffice_invoice_receivable_schedule(...)` dari file
   yang sama, baris `403-455`.
3. `public.get_finance_customer_receipts()`; Credit Note branch dibentuk oleh
   `20260919110000_customer_receipt_credit_note_outstanding_alignment.sql:75-103`.
4. `public.get_backoffice_sales_invoice_payment_context_before_unified_revision(...)`
   dari `20260928110000_backoffice_posted_invoice_price_correction.sql:935-1015`.
5. native Backoffice branch `public.get_finance_ar_aging(...)` dari
   `20261006140000_backoffice_unified_posted_invoice_revision.sql:1248-1286`.
6. `private.plan_backoffice_invoice_revision_journals(...)` dari file yang
   sama, baris `623-670`.

Task 3 Receipt save/post guards memakai receivable helper di atas sehingga ikut
wajib diregresi.

Task 4 hanya mencegah keenam consumer tersebut menganggap Credit Note baru sudah
teralokasi ke source Invoice. Baris open credit terpisah sudah tersedia melalui
RPC open-item Task 2. Penyajian open credit sebagai baris negatif/credit pada
report AR Aging formal tetap Task 7; karena itu Task 4 tidak boleh diklaim
sebagai closure UI/report Finance lengkap.

### 3.3 Consumer yang dipertahankan

- `public.get_finance_customer_statement(...)` tetap mencatat seluruh Credit
  Note sebagai credit AR; allocation tidak mengubah net AR Customer.
- Retail aging/Receipt helper `RETAINED_RETAIL` tetap memakai behavior lama.
- Refund posting/history lama tetap membaca historical Refund Liability.
- Customer Balance dan price correction tidak diubah.

## 4. Identifier sources

| Identifier | Defining/active source |
|---|---|
| Credit Note AR/refund columns + constraint | `20260917130000_backoffice_sales_return_credit_note_foundation.sql:141-178` |
| public native/Retail dispatcher | `20260918150000_retained_retail_credit_note_refund_bridge.sql:757-772` |
| native post core | `20261006140000_backoffice_unified_posted_invoice_revision.sql:2030-2245` |
| open-item tables/audit | `20261105100000_backoffice_ar_open_item_foundation.sql:67-264` |
| Task 3 guard/registration | `20261105110000_backoffice_ar_invoice_receipt_allocation_runtime.sql:73-325` |
| category required functions | `20260722150000_g2_phase16_finance_master_foundation.sql:429` |

Calon helper `private.ar4_backoffice_invoice_allocated_credit(uuid,uuid,date)`
belum dianggap live dan hanya boleh dipakai setelah preflight membuktikan tidak
ada collision.

## 5. Accounting and operational boundaries

- **Stock / Reservation / FIFO / HPP:** tidak berubah; physical Return terjadi
  sebelum Credit Note.
- **Payment:** Receipt Journal tetap satu Cash/Bank-to-AR Journal. Eligibility
  dan stale outstanding harus memakai allocation-based credit.
- **POS / cashier session:** tidak berubah dan tidak menjadi dependency.
- **Finance:** full Credit Note mengkredit AR; tidak ada fake refund, Customer
  Balance entry, atau Cash/Bank movement.
- **Audit:** operation/audit Credit Note dipertahankan; Registry insert diaudit
  trigger Task 2.
- **Concurrency/retry:** operation lock, row locks, expected version dan exact
  retry dipertahankan. Registrasi Registry idempotent dan memverifikasi immutable
  identity jika row sudah ada.
- **Rollback:** posting dan registrasi harus satu transaksi; kegagalan Registry
  menggagalkan Journal/Event/Credit Note.
- **Historical compatibility:** Posted Journal dan data lama immutable.
  Allocation Task 2 menjaga Invoice lama sama seperti sebelum cutover.

## 6. As-of semantics

Allocation Credit Note historis Task 2 mewakili penerapan pada tanggal Credit
Note. Consumer `p_as_of` Task 4 dapat memakai `CREDIT_NOTE.document_date <=
p_as_of` karena Task 4 belum membuka allocation manual. Task 5 wajib menambah
effective allocation date sebelum manual apply-credit aktif; `created_at`
backfill tidak boleh dipakai sebagai tanggal historis.

## 7. Tax boundary

Keputusan user menahan Company dengan `tax_sales_enabled` sampai Finance/Tax
menentukan treatment pajak/e-Faktur. Preflight menjadi `BLOCKER` bila Tax aktif.

## 8. Regression matrix Fase B

- Invoice unpaid/partial paid/fully paid;
- Credit Note kecil/sama dengan residual dan source Invoice sudah lunas;
- exact retry, changed retry, stale version, duplicate Registry, concurrency;
- open/closed/prior accounting period;
- legacy native Credit Note tetap full allocated;
- new Credit Note menjadi open credit penuh dengan zero allocation;
- Receipt setelah Credit Note baru tetap melihat Invoice belum berkurang;
- schedule, payment context, Receipt workspace, AR Aging, dan revision plan
  memakai allocation-based credit;
- Customer Statement tetap debit Invoice + credit Credit Note;
- retained Retail, POS, Stock/FIFO, price correction, Customer Balance, legacy
  liability/refund tetap sama;
- same/cross Company, same/different Customer, dan full rollback.

## 9. State dan unknown

- Repository active call chain: `PROVEN`.
- Task 2/3 Production sebelumnya: `DATABASE LIVE`, behavior dan closing
  postflight PASS berdasarkan output user.
- Task 4 Production: preflight user membuktikan `NOT_INSTALLED`; ledger/helper
  belum ada, exact active runtime digests cocok, KMS/LSM/SMS adalah Backoffice
  non-tax, historical native Credit Note fully allocated, dan queue idle.
- Task 3 client Draft save/reload smoke PASS tanpa posting; Draft
  `CR/2026/11/000594` tidak boleh diposting oleh Task 4.
- Unknown yang dapat mengubah desain: `NONE` pada saat SOP Gate Fase B.

## 10. Fase B local package

- Guarded migration:
  `supabase/migrations/20261105120000_backoffice_ar_credit_note_open_credit_runtime.sql`.
- SELECT-only postflight:
  `supabase/diagnostics/backoffice_ar_credit_note_open_credit_postflight.sql`.
- Rollback behavior utama:
  `supabase/tests/backoffice_sales_return_credit_note_behavior.sql`.
- Receipt regression diperbarui agar native Backoffice membaca allocation
  eksplisit sedangkan retained Retail tetap memakai AR reduction historis:
  `supabase/tests/customer_receipt_credit_note_outstanding_behavior.sql`.
- Manual rollout/forward-fix boundary:
  `docs/runbooks/BACKOFFICE_AR_CREDIT_NOTE_OPEN_CREDIT_ROLLOUT_2026-11-05.md`.

Known boundary: suite `backoffice_sales_customer_refund_behavior.sql` mewakili
flow lama yang membuat Credit Note native baru lalu langsung menciptakan Refund
Liability. Task 4 sengaja menghapus outcome tersebut untuk Credit Note baru;
replacement manual apply/refund/convert tetap Task 5 dan belum boleh diklaim.

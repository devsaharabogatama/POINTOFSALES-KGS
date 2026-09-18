# Backoffice Sales Return & Refund — Impact Audit

## Status

`IMPACT AUDIT COMPLETE - STEP 4/5 REFUND SETTLEMENT LOCAL READY`.

## Outcome yang diminta

Membangun flow Retur & Refund khusus Backoffice Sales tanpa mengubah Retur
Retail, tanpa menghapus histori SO/DO/Invoice, dan tanpa menggandakan efek Stock
atau Finance.

## Execution path existing yang diaudit

### Retail Return

- Dokumen existing: `sales_return_documents`, `sales_return_lines`,
  `sales_return_refunds`, dan `sales_return_fifo_restorations`.
- `post_sales_return` menggabungkan approval, pengembalian Stock/FIFO, refund
  payment, dan Financial Event dalam satu transaksi.
- Posting membutuhkan source `sales_headers` Retail berstatus posted dan sesi
  kasir pelaksana yang masih open.
- UI existing adalah Approval Return kasir/Store, bukan workflow customer return
  Backoffice.

Kesimpulan: runtime Retail tidak boleh diperluas dengan flag Backoffice. Bentuk
source, session boundary, waktu Stock, Credit Note, dan Refund berbeda.

### Backoffice Sales

- Authority barang diterima Customer berada pada Delivery/Customer Receipt dan
  `accepted_base_qty` per SO line.
- Quantity invoice memakai ledger `returned_before_invoice_base_qty`,
  `draft_invoice_allocated_base_qty`, `invoiced_base_qty`, dan
  `to_invoice_base_qty`.
- SO dapat mempunyai beberapa Invoice dan pembayaran Customer dialokasikan ke
  Invoice, bukan ke Product tertentu.
- Invoice Draft dapat diedit; Invoice posted dan audit final immutable.
- Transaction category serta posting mapping Customer Credit Note sudah
  dispesifikasikan, tetapi codebase belum mempunyai canonical Customer Credit
  Note document runtime yang dapat langsung dipakai oleh flow ini.

## Impact map

### Direct impact

- permission baru Retur & Refund Backoffice;
- Return master/line, operation, audit, dan lineage ke SO/DO/Invoice;
- Inventory Customer Return Receipt serta disposition;
- quantity ledger SO dan allocation ke Invoice source;
- Customer Credit Note document/runtime;
- refund settlement document/runtime;
- UI Sales, Inventory, Invoice, Finance, dan activity log.

### Downstream impact

- Stock Movement, FIFO/cost lineage, damaged stock dan destruction/write-off;
- AR/outstanding Invoice, Customer Receipt allocation, refund liability;
- tax, discount, delivery fee, rounding, accounting period dan Journal;
- invoice status pada SO, customer statement, aging, dan laporan;
- cutover Sales process serta histori dokumen lama.

### Tidak boleh berubah

- Retur Retail existing dan sesi kasir;
- source SO/DO/Invoice posted;
- Supplier Receipt/Purchase Return;
- quantity yang belum benar-benar diterima Customer;
- pembayaran yang sudah posted, kecuali melalui allocation/reversal/refund
  document canonical.

## Risiko regresi utama

1. Mengurangi `to_invoice_base_qty` dua kali ketika Return dan Invoice Draft
   sama-sama direkonsiliasi.
2. Mengembalikan Stock sebelum Gudang menerima barang aktual.
3. Membuat Credit Note untuk quantity yang masih dalam perjalanan.
4. Mengoreksi Invoice yang salah saat satu SO mempunyai beberapa Invoice.
5. Refund lebih besar daripada overpayment setelah Credit Note.
6. Disposition Dihancurkan menambah On Hand lalu gagal melakukan write-off.
7. Retry membuat Receipt, Credit Note, Refund, Movement, FIFO, atau Journal
   ganda.
8. Role Sales, Gudang, dan Finance melewati separation of duties.
9. Alokasi tambahan masuk ke Draft Credit Note tanpa menaikkan version sehingga
   tab lama dapat menimpa state baru.
10. Faktor UOM pecahan gagal pada constraint karena persisted base quantity
    enam desimal dibandingkan dengan hasil perkalian tanpa pembulatan canonical.

## Rencana implementasi aman

### Step 1/5 — Return commercial foundation

- Return master/line, status, source eligibility, cumulative quantity guard;
- immutable operation/audit dan permission;
- link SO/DO/Invoice tanpa efek Stock/Finance;
- read-only preflight, migration, behavioral rollback, dan postflight.

### Step 2/5 — Customer Return Receipt

- dokumen penerimaan Gudang terpisah dari Supplier Receipt;
- quantity aktual dan disposition Masuk Stok/Dihancurkan;
- Stock/FIFO restoration atau damaged receipt + write-off;
- partial receipt, retry, stale version, dan cross-Company test.

### Step 3/5 — Invoice reconciliation dan Credit Note

- Draft Invoice adjustment yang tetap menunggu konfirmasi user;
- allocation Return ke Invoice posted;
- Customer Credit Note per Invoice dan AR reconciliation;
- tax/discount/ongkir/rounding serta closed-period handling.

### Step 4/5 — Refund settlement

- refund hanya dari excess Customer credit/refund liability;
- metode, bukti, approval, posting, journal dan statement;
- partial refund dan exact retry.

Implementasi `20260917150000` menjaga Refund sebagai flow Finance Backoffice:
Cash/Transfer memakai akun Payment Method tanpa POS/Cashier Session, liability
Credit Note dikunci dan dibatasi kumulatif, serta koreksi hanya melalui
source-linked reversal. Stock/FIFO, Return Receipt, Invoice dan Customer Receipt
posted tidak dimutasi. Behavioral rollback mencakup partial, cap, retry,
reversal, Journal, Statement, dan boundary Cashier Session.
Behavioral pertama mencapai reversal lalu menemukan guard Finance global lama
hanya mendukung sumber Manual/Opening. Forward-fix `20260917151000` memperluas
guard secara event-scoped untuk jurnal Customer Refund Automatic/Prior Period;
akun, line number, status posted, dan exact debit/credit reversal tetap wajib.
Tidak ada perubahan pada event Finance lain.

### Step 5/5 — UI, log, report, regression dan rollout

- satu fitur Sales Retur & Refund dengan status barang/credit/refund terpisah;
- tab Inventory Retur Customer;
- link SO/Invoice/activity log;
- authenticated E2E Retail regression, Backoffice return, multi-Invoice,
  partial payment, multi-Company, concurrency dan UAT.

## Rollback/forward-fix boundary

Setiap step additive dan tidak menghapus data. Step berikutnya baru dimulai
setelah preflight/migration/behavior/postflight step sebelumnya PASS. Dokumen
final tidak dihapus saat rollback; kesalahan setelah posting memakai
forward-fix/reversal yang source-linked.

## Decision gate Step 1 — RESOLVED

1. Operator Draft: Owner/Admin/Store Manager/Sales/Sales Admin. Approver:
   Owner/Admin/Store Manager/Sales Admin/Finance; Finance bukan operator Draft.
2. Return boleh dimulai setelah quantity diterima Customer untuk kondisi Invoice
   belum ada, Draft, atau posted.
3. Penerimaan parsial boleh menghasilkan koreksi parsial sebesar quantity aktual
   dengan lineage Return dan Invoice sumber eksplisit.
4. Disposition per line dan split line Product yang sama diperbolehkan.

Migration `20260917110000` mengimplementasikan hanya Step 1: quantity hold saat
Submit, optimistic version, exact retry, permission, dan immutable audit. Tidak
ada Stock, Invoice/Credit Note, Refund, atau Finance posting. Metode refund,
approval refund, tax/ongkir/rounding, serta Invoice pengganti tetap harus ditutup
sebelum Step 3/4 dan tidak boleh diasumsikan.

## Decision gate Step 2 — RESOLVED

- disposition dipilih per receipt line dan boleh split Product yang sama;
- `DESTROY` wajib catatan, tanpa foto dan tanpa approval kedua;
- posting Gudang adalah boundary efek fisik; pengajuan/approval belum mengubah Stock;
- `RESTOCK` mengembalikan On Hand/FIFO berdasarkan Customer Receipt asal;
- `DESTROY` mencatat penerimaan fisik dan write-off atomik tanpa menambah On Hand;
- Invoice/Credit Note, refund dan Finance tetap zero-effect pada Step 2.

Migration `20260917120000` additive dan tidak mengubah Retur Retail maupun
Receipt Supplier. Manual PostgreSQL rollout, authenticated smoke, dan UAT pending.

## Decision gate Step 3 - RESOLVED / IMPLEMENTED LOCALLY

- Finance memilih explicit `UNINVOICED`, `DRAFT_INVOICE`, atau
  `POSTED_INVOICE` per quantity Return Receipt; runtime tidak menebak source.
- Draft Invoice dipotong proporsional dan ditandai untuk reconfirm. Trigger DP,
  tax breakdown, delivery fee dan receivable schedule canonical tetap dipakai.
- Posted Invoice menghasilkan Draft Credit Note per Invoice sumber. Line amount,
  discount dan tax berasal dari immutable Invoice snapshot; residual terakhir
  diserap pada source line.
- Ongkir Credit Note default nol, editable oleh Finance sebelum posting, dan
  dibatasi kumulatif oleh ongkir source Invoice.
- Posting Credit Note atomik membuat Journal seimbang, mengurangi AR lebih dulu,
  lalu mencatat kelebihan sebagai Customer Refund Liability. Pembayaran Refund
  tidak dibuat pada Step 3.
- AR aging dan Invoice payment context dibuat credit-aware. Customer Receipt
  posted tidak ditulis ulang; schedule hanya direkonsiliasi terhadap payment dan
  AR-credit totals.
- Draft replacement Invoice tetap tindakan manual. Cancel/reallocation source
  Credit Note tidak dibuka tanpa keputusan bisnis tambahan.

Direct schema/runtime berada pada migration `20260917130000` dan
`20260917131000`. Status hanya `LOCAL READY`; database rollout, authenticated
smoke dan UAT belum dijalankan.

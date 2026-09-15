# Backoffice Sales Payment Collection — Step 1/3

Status: **DATABASE LIVE; BEHAVIOR + POSTFLIGHT USER-CONFIRMED PASS**  
Target yang diizinkan: Supabase Development terisolasi `fkywtxucmyjvpwdiqpix`  
Production dan staging existing: **tidak disentuh**

## Outcome

Historical-clone evidence 2026-09-15 (`idrufihckscppsyclmsu`, units 48–51):
all four migrations installed after their preflights PASS; mapping/UI/AR/collection
postflights PASS; combined 17-scenario behavior PASS. Preparation uses an
Auth-backed actor and Office-mode setup only in outer rollback, clearing setup
marker before operational RPC. Five active Companies remain Retail afterward.
ODR regression PASS; AR-report regression completed without error. Additional
old Invoice-posting regression stopped BEFORE execution: its fixture still lacks
Office-mode preparation. No actual payment, Invoice or mode switch retained;
mapping backfill persists only in clone. Production/client rollout, final fresh
clone rehearsal, authenticated UI smoke and UAT are not established by this.

Invoice Backoffice berstatus `POSTED` dapat dibayar sebagian atau beberapa kali
melalui dokumen **Penerimaan Customer** canonical. Satu receipt tetap menghasilkan
satu Financial Event dan satu jurnal final:

- Debit Kas/Bank;
- Kredit Piutang Customer.

Status pembayaran bukan field manual pada Invoice. Nilainya diturunkan dari
allocation receipt yang sudah `POSTED`:

- nol: Belum dibayar;
- di atas nol tetapi kurang dari total: Sebagian;
- sama dengan total: Lunas.

Draft receipt tidak mengurangi piutang. Satu receipt dapat mempunyai allocation
Retail dan Backoffice untuk Customer dan Company yang sama, tetapi masing-masing
source memakai foreign key berbeda. Invoice Backoffice tidak pernah dipalsukan
sebagai `sales_headers` Retail.

## Impact map

Direct:

- tabel allocation Backoffice baru;
- dua RPC source-neutral untuk Save Draft dan Post receipt;
- source reconciliation pada Finance poster Customer Receipt;
- `allocated_payment_amount` dan status installment Invoice Backoffice.

Downstream:

- Step 2 akan membaca source tersebut untuk status/histori Invoice dan smart link SO;
- Step 3 akan memasukkannya ke workspace Penerimaan Customer, AR Aging, dan
  Customer Statement gabungan.

Tidak berubah:

- POS checkout dan payment POS;
- Order, Reservation, Stock, FIFO/HPP, Delivery Order, Transit, Customer goods
  receipt, tanggal/nilai/template Invoice;
- posting Invoice Backoffice dan DP application;
- lifecycle Customer Balance advance.

Risiko regression yang diuji: over-allocation, stale version, retry posting,
cross-source total, schedule installment, jurnal tidak balance, dan perubahan
tidak sengaja pada allocation/Sales Retail.

## Urutan manual wajib

Jalankan file utuh, jangan selected text:

1. [Preflight](../../supabase/diagnostics/backoffice_sales_payment_collection_preflight.sql)
2. Pastikan tidak ada `BLOCKER` atau SQL error.
3. [Migration](../../supabase/migrations/20260911160000_backoffice_sales_payment_collection_runtime.sql)
4. [Preflight mapping forward-fix](../../supabase/diagnostics/backoffice_sales_payment_account_mapping_fix_preflight.sql)
5. [Migration mapping forward-fix](../../supabase/migrations/20260911161000_backoffice_sales_payment_account_mapping_fix.sql)
6. [Postflight mapping forward-fix](../../supabase/diagnostics/backoffice_sales_payment_account_mapping_fix_postflight.sql)
7. [Behavioral test](../../supabase/tests/backoffice_sales_payment_collection_behavior.sql)
8. [Postflight](../../supabase/diagnostics/backoffice_sales_payment_collection_postflight.sql)
9. Regression existing:
   - `supabase/tests/odr_phase6d_consumer_compatibility_behavior.sql`;
   - `supabase/tests/finance_ar_reporting_behavioral_test.sql`;
   - `supabase/tests/backoffice_sales_invoice_posting_runtime_behavior.sql`.

Hentikan pada SQL error, `BLOCKER`, atau `FAIL`. Jangan menjalankan migration
ulang bila ledger `20260911160000` sudah ada; siapkan forward-fix additive.

Jika `20260911160000` sudah berhasil sebelum mapping defect ditemukan, mulai
langsung dari langkah 4. Forward-fix `20260911161000` memprovisi fallback
`CASH_DRAWER`, `BANK`, dan `CUSTOMER_RECEIVABLE` dari akun sistem canonical;
ia tidak mengubah Invoice, receipt, Journal, atau mapping custom yang sudah aktif.

## Behavioral coverage

Test membuat sendiri pada transaksi rollback:

- SO Backoffice → Dispatch → penerimaan barang Customer → Invoice posted;
- pembayaran pertama 40% dan status installment `PARTIALLY_PAID`;
- pembayaran kedua sampai `PAID`;
- Draft receipt tidak mengubah outstanding;
- stale version dan over-allocation ditolak;
- exact retry tidak membuat Journal kedua;
- Journal receipt balance dan Retail allocation/Sales tidak berubah.

Test tidak mensyaratkan Company kedua dan tidak memakai source identity buatan.
Ia membutuhkan master canonical yang memang dipakai runtime: Company, Store,
Warehouse sale source, Product-UOM, Payment Method Kas/Bank, Accounting Period
terbuka, serta mapping Finance Invoice/Receipt. Bila Company belum memiliki
Customer aktif non-system, test membuat Customer fixture melalui RPC canonical
`save_customer_with_pricelist` dengan kode eksplisit dan menghapus seluruh
efeknya melalui `ROLLBACK`.

## Rollback / forward-fix

Sebelum ada data allocation Backoffice dan sebelum Step 2 client dipakai,
rollback teknis dapat menghapus dua RPC publik, dua helper private, trigger,
index, dan tabel baru, lalu mengembalikan definisi
`private.post_customer_receipt_financial_event_core` dari migration
`20260827110000`.

Setelah satu receipt Backoffice `POSTED`, jangan drop atau mengubah histori.
Koreksi wajib memakai forward-fix additive. Jurnal final tidak boleh diedit;
koreksi bisnis memakai reversal/credit-note flow yang dibuka tersendiri.

Mapping forward-fix tidak boleh di-rollback setelah Customer Receipt memakai
mapping tersebut. Sebelum pemakaian, rollback teknis hanya boleh dilakukan
dengan forward migration terkontrol yang menghapus trigger/helper dan mapping
yang terbukti dibuat oleh rollout; jangan menghapus fallback berdasarkan nama
fungsi saja karena dapat mencakup konfigurasi Finance milik user.

## Status completion

- LOCAL READY: setelah file dan static checks selesai.
- DATABASE LIVE: setelah migration berhasil pada isolated Development.
- BEHAVIOR/POSTFLIGHT PASS: hanya setelah output user seluruhnya bersih.
- CLIENT DEPLOYED / SMOKE PASS / UAT PASS: belum termasuk Step 1.

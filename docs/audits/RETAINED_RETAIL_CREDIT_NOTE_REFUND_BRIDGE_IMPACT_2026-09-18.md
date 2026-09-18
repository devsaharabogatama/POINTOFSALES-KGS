# Retained Retail Credit Note and Refund Bridge Impact

## Outcome

Retur berlabel `RETAINED_RETAIL` yang sudah diterima Gudang dapat melanjutkan
koreksi tagihan terhadap Invoice Retail asal, mem-posting Credit Note, dan
membayar liability Refund melalui flow Finance Backoffice tanpa POS atau
Cashier Session.

## Proven defect

Client menampilkan aksi koreksi untuk seluruh Return yang sudah diterima, tetapi
RPC `allocate_backoffice_sales_return_invoices` hanya dapat menemukan
`backoffice_sales_order_lines`. Retur Retail sengaja menyimpan
`sales_order_line_id = NULL` dan `retail_sales_detail_id` sebagai lineage.
`SELECT INTO STRICT` pada jalur native tersebut menghasilkan `query returned no
rows`.

## Impact map

- Direct: source discriminator pada Credit Note, line allocation dan Refund;
  dispatcher allocation/posting; source Invoice workspace; payment context.
- Finance downstream: AR Aging dan Customer Statement mengakui
  `ar_reduction_amount` dari Credit Note Retained Retail.
- Preserved: Invoice Retail, Sale, Payment, Customer Receipt, Stock Movement,
  Return Receipt/disposition, FIFO/cost lineage dan jurnal historis immutable.
- Native Backoffice: dispatcher mendelegasikan kembali ke runtime lama tanpa
  mengubah payload atau behavior.
- Compatibility: seluruh row existing diberi default `BACKOFFICE`; tidak ada
  business-row backfill.

## Finance policy

- nilai koreksi Product memakai nilai immutable baris Retail secara
  proporsional, termasuk tax dan allocated document rounding;
- piutang yang masih outstanding dikurangi terlebih dahulu;
- bagian Credit Note yang melebihi outstanding menjadi
  `CUSTOMER_REFUND_LIABILITY`;
- prior native Retail Return dan prior retained Credit Note ikut membatasi nilai
  kumulatif agar tidak melebihi Invoice sumber;
- Refund tetap menggunakan Payment Method, account mapping, periode, journal,
  retry dan reversal canonical yang sudah ada.

## Rollout boundary

Urutan wajib: SELECT-only preflight, migration transactional, rollback-only
behavior, postflight, client deploy, authenticated smoke. Stop pada SQL error,
`BLOCKER`, atau `FAIL`. Migration tidak dijalankan oleh agent.


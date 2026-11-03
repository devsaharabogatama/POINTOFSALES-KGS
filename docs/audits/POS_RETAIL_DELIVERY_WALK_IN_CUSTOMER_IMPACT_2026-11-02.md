# POS Retail Delivery dengan Pelanggan Umum — Impact Audit

Tanggal audit: 2026-11-02
Klasifikasi: `PRODUCT_BEHAVIOR_CHANGE`
Status fase: `LOCAL READY`; database dan production client tidak berubah.

## Expected business outcome dan source of truth

Keputusan user terbaru: transaksi POS Retail boleh memakai `DELIVERY` dengan
Customer apa pun, termasuk Customer sistem Walk-In/Pelanggan Umum. Kasir tidak
boleh dipaksa mengganti Customer hanya karena barang dikirim.

Keputusan ini memperbarui batas lama pada
`docs/SLD_DELIVERY_FEE_REVISION_PLAN.md` yang meminta identitas penerima Walk-In
diisi eksplisit. Kontrak dokumen terbaru pada
`docs/SALES_INVOICE_DELIVERY_DOCUMENT_SPEC.md` bagian 12 tetap berlaku: hanya
nama penerima yang wajib; telepon, alamat, rencana kirim, catatan, dan ongkir
opsional. Karena Customer Walk-In adalah row Customer canonical, nama
`Pelanggan Umum`/nama master Walk-In dapat menjadi default nama penerima dan
tetap dapat dikoreksi pada snapshot transaksi.

## Active execution path dan identifier source

1. `pwa/src/App.tsx` `refreshCatalog()` memilih Customer `isWalkIn` sebagai
   default bila Customer aktif sebelumnya tidak ditemukan.
2. `selectFulfillmentMode('DELIVERY')`, `selectCustomer()`, effect policy
   `ALL_POSTED_SALES`, dan `resetSale()` saat ini secara eksplisit mengubah nama
   penerima Walk-In menjadi string kosong melalui kondisi `isWalkIn ? '' :
   name`.
3. `persistDraft()` dan `executeQueueOfflineSale()` menolak `DELIVERY` bila
   `deliveryRecipientName.trim()` kosong dengan
   `DELIVERY_RECIPIENT_REQUIRED`.
4. `pwa/src/lib/pos.ts` `saveSaleDraft()` meneruskan `customerId` dan snapshot
   `deliveryRecipientName` ke RPC `save_pos_sale_draft_with_ketul(jsonb)`.
5. `supabase/migrations/20261031110000_pos_ketul_customer_intake_offset.sql`
   membuktikan wrapper tersebut mendelegasikan penyimpanan Sale canonical dan
   tidak memperkenalkan larangan Walk-In untuk Delivery.
6. `supabase/migrations/20260811143000_sld_r2_post_reprice_delivery_fee_fix.sql`
   mendefinisikan wrapper `save_pos_sale_draft(jsonb)` untuk fulfillment/ongkir;
   tidak ada guard `is_system_customer` pada Delivery.
7. `supabase/migrations/20260827152000_sales_delivery_optional_contact.sql`
   mendefinisikan `private.require_delivery_recipient_name(text)` dan
   server-authoritative `DELIVERY_RECIPIENT_REQUIRED`.
8. `supabase/migrations/20261030130000_pos_retail_pickup_document_boundary.sql`
   adalah consumer dokumen aktif yang tetap memakai helper nama penerima untuk
   Delivery.
9. `supabase/migrations/20260722010000_g2_phase8_customer_foundation.sql`
   mendefinisikan Customer tipe `WALK_IN` sebagai Customer sistem canonical per
   Company; dengan demikian `customerId` tidak perlu dan tidak boleh
   dihilangkan.

## State migration/database

Tidak ada perubahan schema atau migration yang diperlukan. Runtime database
existing sudah menerima Customer Walk-In sebagai `sales_headers.customer_id`
dan hanya mewajibkan snapshot nama penerima untuk Delivery. State object yang
relevan terbukti dari defining migration repository; state ledger production
tidak diperlukan karena patch tidak mengubah object database.

## Impact map

### Direct impact

- PWA mengisi default `deliveryRecipientName` dari `activeCustomer.name` untuk
  semua Customer, termasuk Walk-In.
- Delivery dengan Pelanggan Umum dapat disimpan/diposting tanpa harus memilih
  Customer reguler atau mengetik ulang nama penerima.
- Nama penerima tetap dapat diedit untuk identitas penerima aktual.

### Downstream impact

- `customerId`, pricing/Pricelist, Sale, Invoice, dan Surat Jalan tetap memakai
  Customer canonical yang dipilih.
- Snapshot Surat Jalan untuk Walk-In akan berisi nama master Walk-In bila kasir
  tidak mengubahnya.
- Online Draft/Post dan Offline queue memakai default yang sama.

### Explicitly preserved

- nama penerima Delivery tetap wajib server-side;
- Pickup tidak membuat/menyimpan data Delivery;
- Customer reguler tetap menjadi default penerima dan tetap editable;
- Backoffice/ODR, Tempo, Pricelist, Customer Balance, Payment/split payment,
  Cashier Session, Stock, Reservation, FIFO/HPP, Finance Event/Journal, audit,
  retry/idempotency, stale version, dan tenant boundary tidak berubah;
- tidak ada historical rewrite, schema write, production write, atau deploy.

### Regression risk

- reset transaksi atau policy `ALL_POSTED_SALES` dapat kembali mengosongkan
  penerima bila salah satu dari empat assignment tidak diperbarui;
- Draft existing dengan snapshot penerima kosong tetap harus meminta nama saat
  dibuka, karena patch tidak merekonstruksi histori;
- perubahan server guard akan memperluas dampak ke Backoffice/Surat Jalan dan
  karena itu dilarang dalam task ini.

## Concurrency, idempotency, retry, rollback/forward-fix

Tidak ada mutation server baru. Client hanya mengubah default sebelum payload
canonical disimpan. Master version, lock Draft, posting idempotency key, dan
exact retry tidak berubah. Rollback adalah mengembalikan empat assignment nama
penerima PWA dan copy UI/test terkait; tidak ada rollback database.

## Kondisi belum terbukti

Tidak ada unknown yang mengubah desain. Authenticated Production smoke dan UAT
tetap belum terbukti sampai client dideploy dan user menjalankan Delivery nyata.

## Test matrix

| Skenario | Expected | Coverage |
|---|---|---|
| Retail POS, default Walk-In, Delivery Draft | Customer tetap Walk-In; recipient otomatis nama Walk-In; save sukses | Playwright mocked |
| Retail POS, named Customer, Delivery | recipient otomatis nama Customer dan editable | existing path + focused assertion |
| Pickup | data Delivery kosong dan tidak berubah | existing regression |
| Offline Delivery | nama default ikut payload; guard kosong tetap aktif | build/static path + suite existing |
| Policy `ALL_POSTED_SALES` dan reset transaksi | Walk-In tetap mendapat default recipient | focused assertion/static path |
| Tempo, payment, split payment, Stock/FIFO, Finance | tidak ada perubahan call chain | full POS regression; no new DB behavior |
| Backoffice/ODR | tidak berubah | runtime contract/static boundary |
| same/cross Company, retry, stale version | tenant/customer ID dan canonical guards tetap sama | full POS regression; no new mutation |
| Production authenticated smoke | pilih Pelanggan Umum, Delivery, save/post, cek Invoice/SJ | manual gate setelah deploy |

## Local evidence

- PWA production build: PASS.
- PWA lint: PASS.
- Focused mocked browser Delivery: `2/2 PASS`; membuktikan Walk-In tetap
  menjadi `customerId`, nama Walk-In otomatis menjadi penerima, Draft tersimpan,
  dan named Customer tetap editable.
- Full mocked POS browser/runtime suite setelah static contract final:
  `33/33 PASS`.
- Static contract menjaga empat jalur default/reset, canonical `customerId`,
  dan server-side recipient requirement.

Status yang belum terbukti: `CLIENT DEPLOYED`, authenticated `SMOKE PASS`, dan
`UAT PASS`.

## Manual gate

Setelah client yang tepat dideploy, login sebagai Kasir pada Company Retail,
biarkan Customer aktif `Pelanggan Umum`, masukkan Product, pilih `Perlu
dikirim`, lalu pastikan nama penerima otomatis terisi tetapi masih dapat diedit.
Simpan Draft dan selesaikan satu transaksi representatif; cek Invoice dan Surat
Jalan memakai Customer canonical dan snapshot penerima yang sesuai.

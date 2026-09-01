# Negative Stock FIFO Finance Cost Settlement

## Status

`NSC-1..3 RUNTIME INSTALLED / AUTHENTICATED OPERATIONAL SMOKE PENDING`.
Preflight, foundation postflight, dan runtime postflight live telah ditinjau
tanpa blocker/fail dan tanpa variance historis nonnol. Cost source baru masih
nol, sehingga closure menunggu transaksi smoke nyata.

## Outcome

Menutup selisih antara FIFO, Inventory GL, dan COGS ketika barang sudah dikirim
sebelum layer FIFO penerimaan tersedia, tanpa mengubah alur kerja Kasir, Gudang,
Goods Receipt, Supplier Invoice, atau controlled Finance queue.

## Kontrak yang dikunci

1. Dispatch tetap mengonsumsi FIFO positif paling lama terlebih dahulu.
2. Kekurangan Dispatch membentuk negative allocation dengan COGS provisional.
3. Goods Receipt membentuk layer terpisah per batch dengan biaya estimasi.
4. Layer baru menutup negative allocation tertua sebelum sisanya menjadi FIFO
   tersedia.
5. Selisih COGS provisional Dispatch terhadap biaya estimasi Goods Receipt
   dijurnal sebagai koreksi COGS versus Inventory.
6. Supplier Invoice tidak mengubah jurnal Sale atau Goods Receipt historis.
   Selisih harga aktual dibagi menjadi:
   - `inventory_variance` untuk quantity batch yang masih tersisa; dan
   - `hpp_variance` untuk quantity yang sudah keluar, termasuk quantity yang
     menutup stok minus.
7. `product_batches.cogs_unit` hanya direvaluasi bersamaan dengan jurnal biaya
   yang sah. Tidak boleh ada jendela ketika FIFO sudah berubah tetapi GL belum.
8. Cost source memperkaya Event Goods Receipt/Supplier Invoice canonical yang
   masih `HOLD`; posting tetap melalui queue pada Company `CONTROLLED`,
   source-linked, exact-retry, tenant-safe, period-aware, dan transactional.
9. Jurnal `POSTED` tidak ditulis ulang. Data historis memakai adjustment event
   append-only.
10. Rekonsiliasi Inventory membandingkan GL dengan nilai FIFO bersih:
    FIFO positif dikurangi provisional negative allocation terbuka, ditambah
    adjustment yang masih memiliki status Finance yang eksplisit.

## Flow user setelah rollout

1. Kasir mengonfirmasi Order seperti biasa.
2. Gudang Dispatch seperti biasa. Stok minus yang diizinkan tersimpan sebagai
   negative allocation dan COGS provisional.
3. Gudang menerima barang seperti biasa. Server mengalokasikan batch baru ke
   shortage tertua dan menyiapkan koreksi biaya.
4. Finance memvalidasi Supplier Invoice seperti biasa. Server menyiapkan split
   variance Inventory/HPP dan revaluasi batch.
5. Pada mode `CONTROLLED`, Finance memproses event melalui preview/approve/
   process queue yang sama. Kasir dan Gudang tidak menunggu Finance real-time.
6. Diagnostic/postflight menampilkan provisional terbuka, settlement,
   revaluasi, dan variance secara terpisah.

## Tahapan delivery

### NSC-0 — Preflight dan klasifikasi historis

- memastikan queue tidak aktif;
- menginventaris negative allocation dan replenishment;
- memisahkan Goods Receipt/Supplier Invoice `HOLD` dan `POSTED`;
- memeriksa mapping `INVENTORY_ASSET`, `COGS`, dan
  `PURCHASE_PRICE_VARIANCE`;
- tidak melakukan write.

### NSC-1 — Settlement foundation

- menambah immutable cost-settlement source dan batch-cost allocation;
- menyimpan source variance, remaining/sold snapshot, Inventory variance, HPP
  variance, akun immutable, serta relasi Invoice-allocation ke FIFO batch;
- private-only mutation dan RLS/read boundary.

### NSC-2 — Goods Receipt negative-cost settlement

- settlement dibuat atomik saat batch baru menutup shortage;
- Goods Receipt `HOLD` membawa snapshot koreksi;
- rollout berhenti bila ditemukan Goods Receipt historis `POSTED` dengan
  variance nonnol; database live yang ditinjau tidak memiliki kasus tersebut;
- exact retry tidak menggandakan settlement atau jurnal.

### NSC-3 — Supplier Invoice split dan FIFO revaluation

- invoice allocation dipetakan deterministik ke receipt batch;
- revaluasi `cogs_unit` batch tersisa dan jurnalnya terjadi dalam transaksi
  posting yang sama;
- quantity terjual masuk Selisih Harga Beli/HPP;
- rollout berhenti bila ditemukan Invoice historis `POSTED` dengan variance
  nonnol; database live yang ditinjau tidak memiliki kasus tersebut.

### NSC-4 — Reconciliation dan closure

- FIFO/negative provisional/GL reconciliation;
- dispatch minus -> partial receipt -> final receipt -> partial invoice ->
  final invoice -> controlled posting;
- retry, stale version, period locked, missing mapping, cross-tenant, Return,
  dan journal balance tests.

## In scope

- negative stock replenishment cost;
- Goods Receipt estimated cost;
- Supplier Invoice actual cost;
- FIFO batch valuation, COGS/Inventory variance, Finance event/journal;
- diagnostics, migration, behavior, postflight, dan reconciliation.

## Out of scope

- mengubah izin stok minus;
- mengubah urutan FIFO menjadi pemilihan batch manual;
- mengubah alur POS/Dispatch/Goods Receipt/Supplier Invoice;
- mengaktifkan mode posting otomatis;
- mengedit jurnal `POSTED`;
- landed cost baru di luar komponen Supplier Invoice yang sudah tersedia.

## Manual gate NSC-0

Jalankan:

```text
supabase/diagnostics/negative_stock_fifo_finance_cost_settlement_preflight.sql
```

Stop bila terdapat `BLOCKER`. `BACKFILL` bukan kegagalan, tetapi wajib masuk
jalur adjustment append-only pada migration berikutnya. Jangan menjalankan
migration NSC-1 sebelum output preflight ditinjau.

## Urutan rollout manual NSC-1..3

1. Jalankan ulang preflight NSC-0 terbaru. Versi terbaru juga memeriksa mapping
   `COGS` pada kategori Supplier Invoice. Stop pada `BLOCKER`/`BACKFILL`.
2. Jalankan migration `20260831120000_negative_stock_fifo_finance_cost_foundation.sql`.
3. Jalankan `negative_stock_fifo_finance_cost_foundation_postflight.sql`; semua
   pemeriksaan wajib `PASS`.
4. Jalankan migration `20260831130000_negative_stock_fifo_finance_cost_runtime.sql`.
5. Jalankan `negative_stock_fifo_finance_cost_runtime_behavior.sql`; seluruh
   write test di-rollback.
6. Jalankan `negative_stock_fifo_finance_cost_runtime_postflight.sql`; stop pada
   `FAIL`.
7. Smoke operasional terautentikasi: Dispatch stok minus, Goods Receipt parsial
   lalu final, process queue, validasi Supplier Invoice dengan harga berbeda,
   process queue lagi, lalu cocokkan FIFO/Inventory/COGS. Sertakan exact retry
   dan Goods Receipt harga nol.

Migration tidak mengaktifkan automatic posting dan tidak mengubah UI.

## Forward-fix / rollback

- NSC bersifat additive; jurnal final tidak dihapus atau ditulis ulang.
- Sebelum event diposting, rollout dapat dihentikan dengan membiarkan source
  berstatus pending/HOLD.
- Setelah event diposting, koreksi wajib melalui reversal/adjustment baru.
- Tidak ada rollback yang mengembalikan `product_batches.cogs_unit` tanpa
  pasangan jurnal dan audit.

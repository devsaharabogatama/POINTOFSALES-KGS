# Purchase Daily Replenishment Step 3/6 — AUTO_RO Runtime

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT; AUTHENTICATED SMOKE/UAT PENDING**  
Target wajib: `fkywtxucmyjvpwdiqpix`  
Production dan staging lama: **jangan disentuh**

## Outcome

Gate ini mengaktifkan dua mutation baru:

1. generator atomik `AUTO_RO` setelah cutoff pukul 23:59 waktu Company;
2. konfirmasi RO harian menjadi PO per Supplier, ditambah satu kelompok
   `SUPPLIER_PENDING` bila Supplier belum diketahui.

`purchase_daily_batches` adalah RO internal lintas-Gudang milik Company. Gate
ini sengaja tidak memakai `stock_request_documents` untuk RO otomatis karena
tabel legacy tersebut wajib mempunyai Store, POS, dan Cashier Session.

PO hasil daily replenishment memakai scope `COMPANY_MULTI_WAREHOUSE`. Gudang
sumber dan Gudang penerimaan berada pada tiap line; Store dan Gudang header PO
kosong hanya untuk source ini. PO manual/legacy tetap wajib Store, satu Gudang
header, dan Supplier.

## Batas Gate

- Mode `MANUAL` dan `AUTO_PO` ditolak oleh generator AUTO_RO.
- Business date wajib tanggal lokal Company dan cutoff harus sudah tercapai.
- Satu Company/tanggal hanya mempunyai satu batch; operation key dan batch
  uniqueness menjaga retry. Operation baru pada tanggal yang sama memakai batch
  yang sudah ada, dicatat sebagai `REUSE`, dan tidak membuat RO kedua.
- Draft daily RO sebelumnya ikut coverage hari berikutnya. Setelah dikonfirmasi,
  PO yang menjadi coverage dan RO tidak dihitung kedua kali.
- Konfirmasi menerima split allocation. Satu line dapat dibagi ke beberapa
  Supplier, tetapi seluruh split satu line harus menuju satu Gudang penerimaan.
- Line tanpa Supplier tetap menghasilkan PO `SUPPLIER_PENDING`; penerimaan dan
  penetapan Supplier setelah Receipt baru dibuka pada Step 5/6.
- Line `SUPPLIER_PENDING` memakai base UOM aktif sebagai fallback meskipun belum
  memiliki relasi Supplier/UOM pembelian.
- Gate ini tidak membuat Goods Receipt, Stock Movement, FIFO batch, AP,
  Financial Event, Journal, Supplier Bill, Payment, atau scheduler.

## Urutan Manual

Jalankan setiap file secara utuh pada SQL Editor isolated Development:

1. `supabase/diagnostics/purchase_daily_auto_ro_runtime_preflight.sql`
2. Pastikan tidak ada `BLOCKER` atau SQL error.
3. `supabase/migrations/20260913120000_purchase_daily_auto_ro_runtime.sql`
4. `supabase/diagnostics/purchase_daily_auto_ro_runtime_postflight.sql`
5. `supabase/tests/purchase_daily_auto_ro_runtime_behavior.sql`
6. `supabase/diagnostics/purchase_daily_auto_ro_runtime_postflight.sql` lagi.

Behavioral test hanya memakai satu Company aktif beserta setting Step 1, lalu
membuat Category, Product, Base UOM, Gudang penerimaan, Supplier,
Product-Supplier, saldo negatif, satu RO, dua PO group, dan lineage sendiri di
dalam transaksi rollback. Test tidak memerlukan master Purchase existing, open
Cashier Session, Company kedua, atau fixture PO operasional.

## Expected Evidence

- Semua check preflight: `PASS` atau `INFO`.
- Migration: `Success. No rows returned`.
- Behavior: notice `TEST_PASS` lalu `ROLLBACK`.
- Semua check postflight: `PASS` atau `INFO`.
- `pdr3_runtime_inventory` tetap informasi, bukan bukti behavioral.

Stop jika ada `BLOCKER`, `FAIL`, atau SQL error. Jangan memperbaiki data dengan
query ad-hoc; kirim seluruh error beserta context.

## Authenticated Smoke Setelah SQL PASS

Smoke mutation melalui RPC authenticated baru dilakukan setelah database gate:

1. set Company Development ke `AUTO_RO` sebagai Super Admin;
2. pastikan terdapat On Hand negatif dan Gudang penerimaan valid;
3. setelah cutoff, panggil generator dengan operation UUID;
4. ulangi UUID yang sama dan pastikan `exactRetry=true` dengan `batchId` sama;
5. konfirmasi RO memakai `masterVersion`, line version, dan allocations;
6. pastikan PO assigned/pending serta source/destination line benar;
7. pastikan tidak ada Receipt, Stock Movement, FIFO, AP, Event, atau Journal.

UI operator dan scheduler 23:59 tetap Step 6/6, sehingga SQL PASS tidak boleh
dilabeli authenticated smoke atau UAT PASS.

## Forward Fix / Rollback

Migration additive ini mengubah contract header PO agar nullable hanya untuk
shape `DAILY_REPLENISHMENT`; constraint tetap memaksa seluruh PO manual lama
memiliki Store, Gudang header, dan Supplier. Setelah migration berhasil, jangan
DROP tabel/kolom karena RO/PO dapat mulai terbentuk. Jika gate gagal, hentikan
generator dan buat migration forward-fix baru. Mengembalikan Company ke
`MANUAL` mencegah generation baru tetapi tidak menghapus dokumen yang sudah ada.

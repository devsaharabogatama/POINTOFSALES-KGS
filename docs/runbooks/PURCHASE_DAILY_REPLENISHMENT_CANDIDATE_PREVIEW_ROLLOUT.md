# Purchase Daily Replenishment Step 2/6 — Candidate Preview

## Dampak

Paket ini memisahkan Gudang sumber kekurangan dari Gudang penerimaan per line,
menambahkan default Gudang penerimaan per Company, dan menyediakan preview
read-only berdasarkan `product_stocks.stock_qty < 0`.

Resolver mengurangi dua coverage exact untuk Product-Gudang yang sama:

1. sisa Supplier Order aktif setelah seluruh Goods Receipt `POSTED`;
2. sisa Stock Request aktif yang mempunyai identitas Gudang exact dan belum
   dialokasikan ke Supplier Order aktif.

Stock Request legacy yang tidak mempunyai Gudang exact tidak ditebak. Candidate
Product tersebut diberi `OPEN_REQUEST_WAREHOUSE_AMBIGUOUS` agar generator nanti
tidak membuat pembelian ganda. Reserve dan Transit tidak dibaca.

Tidak ada generator, RO, PO, Receipt, Stock Movement, FIFO, AP, Financial Event,
Journal, atau scheduler yang diaktifkan pada Step 2.

Unique key line legacy tetap berlaku saat pasangan Warehouse masih `NULL`.
Line baru memakai unique Product-UOM-source-destination sehingga Product yang
sama dari dua Gudang pada batch harian tidak saling menolak.

## Urutan isolated Development

Jalankan file lengkap di project `fkywtxucmyjvpwdiqpix`:

1. `supabase/diagnostics/purchase_daily_replenishment_candidate_preview_preflight.sql`;
2. pastikan seluruh check selain `INFO` adalah `PASS`;
3. `supabase/migrations/20260913110000_purchase_daily_replenishment_candidate_preview.sql`;
4. `supabase/diagnostics/purchase_daily_replenishment_candidate_preview_postflight.sql`;
5. `supabase/tests/purchase_daily_replenishment_candidate_preview_behavior.sql`;
6. ulangi postflight.

Behavioral membuat saldo uji hanya di dalam `BEGIN/ROLLBACK`, menghitung formula
coverage, membaca preview, dan membuktikan tidak ada dokumen operasional dibuat.

## Authenticated smoke

1. Restart Backoffice isolated Development dan login `localadmin@local.com`.
2. Buka Pengaturan Modul > Purchase.
3. Pilih Default Gudang penerimaan dan simpan; muat ulang lalu pastikan tetap sama.
4. Panggil `GET /api/purchase/replenishment-preview`; hasil harus hanya berisi
   Company aktif, kandidat On Hand negatif, pilihan Gudang penerimaan aktif, dan
   `generationActive=false`.
5. Jika Gudang sumber juga tujuan pembelian, destination harus sama dengan source.
6. Jika berbeda, destination memakai default Company dan `requiresTransfer=true`.
7. Login user tanpa VIEW Purchase dan pastikan preview ditolak server.

## Rollback / forward-fix

Migration transactional: kegagalan sebelum `COMMIT` mengembalikan seluruh schema.
Setelah applied, jangan edit migration. Perbaikan dilakukan dengan forward migration.
Client dapat di-rollback dengan menghapus selector default dan route preview; kolom
nullable tetap kompatibel dengan dokumen legacy. Tidak ada data final yang di-backfill.

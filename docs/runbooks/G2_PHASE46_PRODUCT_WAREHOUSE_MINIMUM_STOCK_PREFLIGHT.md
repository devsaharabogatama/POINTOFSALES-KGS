# G2 Phase 46 — Product-Warehouse Minimum Stock Preflight

## Status

`READY FOR MANUAL PREFLIGHT`

Phase 45 Product-Supplier Import UI dinyatakan aman oleh user. Phase ini hanya
mengaudit kesiapan minimum stock per Produk–Gudang dan belum membuat schema,
threshold, import job, notice POS, atau Stock Request.

## Kontrak bisnis yang dikunci

Minimum stock adalah konfigurasi opsional per pasangan Produk–Gudang:

```text
Product aktif bertipe STOCK
+ Gudang aktif dalam Company yang sama
+ minimum_stock_base_qty nullable
+ low_stock_alert_enabled
```

Aturannya:

- quantity threshold selalu memakai **base UOM** Produk;
- konfigurasi tidak ditempelkan pada lifecycle saldo `product_stocks`;
- pasangan tanpa saldo/movement tetap boleh dikonfigurasi;
- threshold kosong atau alert nonaktif berarti tidak ada notice;
- minimum stock tidak menambah/mengurangi saldo;
- notice kelak bersifat non-blocking dan tidak membuat Stock Request atau
  Supplier Order otomatis;
- import menggunakan `product_sku` dan `warehouse_name`; UUID/kode teknis
  Gudang tidak perlu diketahui user.

Pemisahan tabel konfigurasi dari `product_stocks` penting karena row saldo
dapat belum ada sebelum movement pertama, sedangkan threshold tetap perlu
disiapkan lebih awal.

## File

Diagnostic:

`supabase/diagnostics/g2_phase46_product_warehouse_minimum_stock_preflight.sql`

## Cara menjalankan

Jalankan seluruh file di Supabase SQL Editor, kemudian kirim tiga kolom:

```text
check_name,status,details
```

Diagnostic bersifat `SELECT`-only, hanya mengembalikan aggregate count, dan
tidak membuka nama Produk/Gudang atau data bisnis.

## Expected

- seluruh row berstatus `PASS` atau `INFO`;
- `g2_phase44_dependency` = `PASS`;
- tidak ada active reference kosong/ambigu;
- setiap Product stock aktif memiliki tepat satu base Product-UOM aktif dengan
  faktor `1`;
- tidak ada orphan/duplicate/negative `product_stocks`;
- setiap pasangan yang memiliki movement mempunyai materialized balance;
- tidak ada import job nonterminal;
- `settings_table_exists`, dukungan job type, dan guarded save RPC masih
  `false` adalah expected `INFO` sebelum migration Phase 46.

`eligible_pairs` bukan jumlah row yang wajib dibuat. Konfigurasi bersifat
opsional, sehingga tidak ada backfill massal untuk seluruh perkalian
Produk–Gudang.

## Stop condition

Jangan lanjut ke migration jika ada `BLOCKER`, khususnya:

- dependency Phase 44 hilang;
- SKU Product atau nama Gudang ambigu;
- base UOM Product tidak valid;
- orphan/duplicate/negative saldo;
- movement tidak mempunyai materialized balance;
- import job masih nonterminal.

Kirim output lengkap agar forward migration tidak menebak live state.

## Setelah preflight PASS

Next safe step:

1. buat tabel konfigurasi tenant-scoped terpisah dari saldo;
2. tambah optimistic version, audit, RLS, dan guarded atomic save;
3. tambahkan fixed import type Minimum Stock tanpa menyentuh stock ledger;
4. buat postflight dan behavioral test untuk tenant, concurrency,
   create/update/disable, partial import, serta no-stock/no-request invariant;
5. baru setelah database gate PASS, sambungkan Backoffice UI.

Opening Stock tetap menunggu G3 dan bukan bagian Phase 46.

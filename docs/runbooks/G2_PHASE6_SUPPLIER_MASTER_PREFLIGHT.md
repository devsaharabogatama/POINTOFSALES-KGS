# Runbook G2 Fase 6 - Supplier Master Preflight

**Scope:** readiness Master Supplier dan relasi Product-Supplier  
**Requirement:** canonical master G2; dependency PUR-001  
**Dependency:** G2 fase 4 database complete dan Product canonical aktif  
**Status:** COMPLETE - LIVE PREFLIGHT PASS; ZERO LEGACY PURCHASE ROWS

## Tujuan

- menginventarisasi `supplier_name` legacy pada Purchase tanpa menampilkan nama;
- menentukan apakah diperlukan backfill Supplier canonical;
- mendeteksi normalisasi nama Supplier yang ambigu;
- memastikan setiap Product STOCK aktif memiliki minimal satu Product-UOM
  pembelian yang valid;
- memastikan tabel `suppliers` dan `product_suppliers` belum dibuat diam-diam.

## Urutan Manual

1. Jalankan seluruh file
   `supabase/diagnostics/g2_phase6_supplier_master_preflight.sql` di Supabase SQL
   Editor.
2. Export atau salin hasil akhir saja.
3. Kirim hasil `check_name,status,details` sebelum migration Supplier ditulis.

## Interpretasi

- `BLOCKER`: hentikan; data/kontrak harus diperbaiki sebelum migration.
- `REVIEW`: ada variasi nama legacy yang memerlukan keputusan mapping.
- `BACKFILL`: bukan otomatis gagal; jumlah tersebut menjadi scope migration
  backfill yang eksplisit.
- `PASS`: aman untuk aspek yang diperiksa.
- `INFO`: inventory untuk menentukan bentuk migration berikutnya.

## Batas Fase

- Belum membuat Supplier Order, Goods Receipt, AP, atau Stock Movement.
- Rekening Supplier hanya reference master; payment Finance belum dibuka.
- Default Supplier/UOM pembelian canonical akan berada di relasi
  Product-Supplier, bukan ditebak dari Product saja.
- Tidak ada deployment Vercel pada tahap preflight ini.

## Evidence 2026-07-21

- seluruh blocker check `PASS`;
- `purchases_headers` kosong sehingga tidak ada Supplier-name backfill;
- satu Product aktif memiliki satu Product-UOM pembelian valid;
- tabel `suppliers` dan `product_suppliers` belum ada sebelum migration.

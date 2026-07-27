# Runbook G2 Fase 11 - Pricelist Preflight

**Status:** READY FOR MANUAL PREFLIGHT  
**Safety:** SELECT-only

## Tujuan

Menginventarisasi kesiapan Product-UOM harga jual, Customer/grouping, histori
Sales, snapshot pricing, browser privilege, serta scope provisioning Global
Pricelist sebelum schema atau resolver harga dibuat.

## Cara Menjalankan

Jalankan seluruh file:

`supabase/diagnostics/g2_phase11_pricelist_preflight.sql`

Kirim seluruh hasil `check_name,status,details`.

## Stop Condition

- `BLOCKER`: jangan membuat atau menjalankan migration.
- `REVIEW`: kirim hasil; histori mungkin membutuhkan aturan backfill eksplisit.
- `BACKFILL` untuk Global default adalah expected dan hanya menyatakan jumlah
  Company aktif yang perlu diprovisikan.
- `INFO` bukan kegagalan.

## Boundary

Fase preflight ini belum membuat Pricelist, resolver harga, diskon POS, Tax,
snapshot transaksi, atau mengubah checkout.

# Runbook G2 Fase 4 - Product CRUD Preflight

**Scope:** kesiapan Product canonical dan Product-UOM atomic write  
**Requirement:** MST-001, MST-002  
**Dependency:** G2 fase 1-3 complete  
**Status:** COMPLETE - LIVE PREFLIGHT CLEAN

## Tujuan

Preflight ini membaca keadaan master riil setelah Category, UOM, dan Warehouse
mulai dikonfigurasi. Hasilnya menentukan migration dan compatibility rule untuk:

- satu Product dan seluruh Product-UOM disimpan sebagai satu transaksi atomic;
- base UOM terkecil mempunyai faktor tepat `1`;
- seluruh UOM lain menyimpan faktor langsung ke base UOM;
- Category, base UOM, dan UOM acuan berat berasal dari Company aktif;
- legacy `category`, `uom`, `price`, dan `cogs` tetap sinkron selama UI lama masih hidup;
- direct browser write untuk logical group Product dapat diganti guarded RPC.

## Langkah Manual

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file:
   `supabase/diagnostics/g2_phase4_product_crud_preflight.sql`.
3. Jangan menjalankan potongan query secara terpisah.
4. Export/copy hasil akhir kolom `check_name,status,details` dan kirimkan ke agent.

Diagnostic ini SELECT-only dan tidak mengubah data yang sudah dibuat melalui
Backoffice.

## Hasil Live 2026-07-21

- Seluruh invariant Product existing `PASS`.
- Product existing: `0`; tidak diperlukan backfill atau movement compatibility.
- Master aktif tersedia: 1 Category, 1 UOM, dan 3 Warehouse.
- Satu Company aktif memiliki Category dan UOM aktif.
- Direct browser write ke Product/Product-UOM masih terbuka dan ditutup oleh
  migration fase 4 melalui guarded atomic RPC.

## Interpretasi

- `BLOCKER`: migration Product atomic belum boleh dibuat sampai penyebabnya jelas.
- `BACKFILL`: ada Product lama yang perlu aturan migrasi eksplisit.
- `REVIEW`: tidak selalu menghalangi, tetapi membutuhkan compatibility decision.
- `PASS`: invariant tersebut siap.
- `INFO`: inventory/evidence untuk menyusun migration, bukan kegagalan.

## Stop Condition

- Jangan membuat Product baru dari UI lama sebelum hasil preflight direview.
- Jangan menghapus Product, UOM, Category, Warehouse, atau conversion untuk
  membuat preflight terlihat bersih.
- Jangan mengubah Product-UOM langsung melalui Table Editor.
- Jangan menjalankan migration baru sebelum agent membuat postflight, behavioral
  test, dan urutan rollout berdasarkan hasil live ini.

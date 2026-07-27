# Runbook G2 Fase 8 - Customer Master Preflight

**Scope:** Customer Category dan canonical Customer foundation  
**Requirement:** G2 canonical master data; Customer contract  
**Dependency:** Supplier foundation `20260721230000` complete  
**Status:** READY FOR MANUAL PREFLIGHT

## Tujuan

Audit ini menentukan kebutuhan expand/backfill sebelum schema Customer ditulis:

- duplicate kode/nama Customer setelah normalisasi;
- nilai saldo atau limit kredit negatif;
- Customer yang sudah mempunyai histori Sales;
- saldo Customer nonzero yang belum mempunyai canonical balance ledger;
- kebutuhan satu system Customer `WALK-IN` per Company aktif;
- kondisi schema Customer Category dan kolom canonical;
- direct browser write privilege yang nantinya harus ditutup oleh guarded RPC.

## Cara Menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file
   `supabase/diagnostics/g2_phase8_customer_master_preflight.sql`.
3. Export atau salin hasil akhir `check_name,status,details`.
4. Jangan menjalankan migration Customer sebelum hasilnya direview.

## Interpretasi

- `BLOCKER`: data harus dibersihkan atau diberi mapping eksplisit sebelum migration.
- `REVIEW`: memerlukan keputusan backfill, terutama saldo Customer nonzero.
- `BACKFILL`: kondisi normal yang akan ditangani migration terkontrol, misalnya
  pembuatan satu Customer `WALK-IN` per Company aktif.
- `PASS`: invariant existing aman.
- `INFO`: inventory/schema/privilege saat ini, bukan kegagalan.

## Batas Fase

- Audit bersifat SELECT-only.
- Belum mengubah form Customer Backoffice.
- Belum membuka quick-create Customer dari POS.
- `current_balance` tidak akan dijadikan field editable.
- Pricelist, TEMPO, Customer Balance ledger, dan Finance posting belum diaktifkan.

# G5 Phase 13 — Supplier Payment / AP Settlement Preflight

Runbook ini berisi panduan eksekusi diagnostik preflight untuk memeriksa kesiapan data baseline sebelum membuka skema database Pembayaran Supplier (**Supplier Payment & AP Settlement Foundation**).

---

## Prasyarat & Keamanan

1. **Database Baseline:**
   - Migration `20260806100000_g5_phase11_supplier_invoice_matching_foundation.sql` telah dieksekusi di Supabase dan dikonfirmasi `PASS`.
   - Forward-fix migration `20260807120000_g5_phase12_flexible_tolerance_default.sql` telah dieksekusi di Supabase.
   - Smoke test UAT Backoffice UI Faktur Supplier (Phase 12) telah Anda lakukan.

2. **Keamanan Eksekusi Script:**
   - Script `supabase/diagnostics/g5_phase13_supplier_payment_preflight.sql` adalah **SELECT-only (strictly read-only)**.
   - Script tidak mengubah data (*zero mutation*), tidak membuat tabel baru, dan aman dijalankan kapan pun di Supabase SQL Editor.

---

## Langkah Eksekusi Manual

1. Buka **Supabase Dashboard > SQL Editor**.
2. Salin seluruh isi file diagnostic:
   `supabase/diagnostics/g5_phase13_supplier_payment_preflight.sql`
3. Jalankan query (*Run*).
4. Catat dan serahkan seluruh hasil row output (kolom `check_name`, `status`, `details`).

---

## Interpretasi Hasil Diagnostic

- **`PASS`:** Syarat baseline terpenuhi; siap melanjutkan ke penyusunan skema database Pembayaran Supplier (Phase 14 Foundation Migration).
- **`SETTLEMENT_CANDIDATE`:** Ditemukan Faktur Supplier berstatus `VALIDATED` yang menjadi kandidat pelunasan AP Final. Ini adalah status informatif normal (*expected*).
- **`INFO`:** Informasi inventori/tabel baseline legacy, bukan kegagalan.
- **`REVIEW`:** Terdapat Kategori Transaksi `SUPPLIER_PAYMENT` yang perlu disiapkan di Master Keuangan perusahaan.
- **`BLOCKER`:** Terdapat integritas data yang melanggar invariant; **hentikan pekerjaan** dan kirim detail error untuk diperbaiki sebelum membuat migration baru.

---

## Cakupan & Batasan Scope Phase 13/14

- Pembayaran Supplier (*Supplier Payment*) hanya melunasi Faktur Supplier yang sah (`VALIDATED`).
- Sistem mencatat referensi transfer bank, tanggal bayar, nominal pelunasan, sisa hutang (*Outstanding AP*), dan menerbitkan Financial Event `SUPPLIER_PAYMENT_SUBMITTED` / `SUPPLIER_PAYMENT_COMPLETED`.
- Jurnal Keuangan umum / Buku Besar G6 (*General Ledger posting*) **tetap tertutup** sampai Gate 6 (G6).

# G5 Optional Supplier Invoice Tolerance — Corrective Forward Fix

File lama `20260807120000_g5_phase12_flexible_tolerance_default.sql` diklaim
sudah pernah dijalankan sebagai function-only script dan tidak menulis migration
ledger. Jangan edit atau rerun file lama.

## Urutan manual

1. Jalankan migration
   `supabase/migrations/20260810160000_g5_optional_tolerance_contract_forward_fix.sql`.
2. Jalankan
   `supabase/diagnostics/g5_optional_tolerance_contract_postflight.sql`.
3. Semua row non-`INFO` wajib `PASS`.
4. Jalankan ulang
   `supabase/tests/g5_phase11_supplier_invoice_matching_tests.sql`.
5. Jalankan ulang
   `supabase/diagnostics/g5_phase14_supplier_payment_postflight.sql`.

## Kontrak

- tanpa policy: value variance fleksibel dan tetap terlihat;
- dengan policy: threshold Company/Supplier tetap authoritative;
- quantity tidak boleh melampaui/meninggalkan allocation Receipt eligible;
- tidak ada Stock/FIFO/Movement dari Supplier Invoice;
- fungsi private tidak executable oleh browser.

Setelah seluruh langkah PASS, jalankan G6 Corrective Phase 1 preflight. Jangan
menjalankan draft migration G6 yang sudah dikarantina.

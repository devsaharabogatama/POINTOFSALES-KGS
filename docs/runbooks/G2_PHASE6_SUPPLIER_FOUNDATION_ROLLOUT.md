# Runbook G2 Fase 6 - Supplier Foundation Rollout

**Scope:** Supplier dan relasi Product-Supplier canonical  
**Requirement:** canonical master G2; dependency PUR-001  
**Dependency:** G2 fase 4 complete; Supplier preflight clean  
**Status:** COMPLETE (DATABASE)

## Evidence

- migration `20260721230000` berhasil diterapkan di Supabase;
- seluruh 9 pemeriksaan postflight `PASS`;
- behavioral test Supplier/Product-Supplier menghasilkan `TEST PASSED`;
- user mengonfirmasi hasil database `ALL GOOD` pada 21 Juli 2026;
- API/UI Backoffice dilanjutkan terpisah pada runbook fase 7 agar evidence database
  tidak tercampur dengan smoke test aplikasi.

## Perubahan

- tabel `suppliers` tenant-scoped dengan kode/nama unik ternormalisasi, status,
  kontak, NPWP, payment term, dan satu rekening referensi;
- tabel `product_suppliers` menghubungkan Product, Supplier, dan Product-UOM
  pembelian dalam Company yang sama;
- maksimal satu Supplier aktif yang preferred per Product;
- `reference_purchase_price` editable sebagai referensi, sedangkan
  `last_purchase_price` tidak tersedia pada RPC browser dan disiapkan untuk
  invoice Finance tervalidasi;
- optimistic `master_version`, touch trigger, serta audit before/after;
- authenticated tidak memiliki direct INSERT/UPDATE/DELETE;
- mutation hanya melalui `save_supplier` dan `save_product_supplier` dengan
  active Company dan role guard;
- Cashier tidak memperoleh visibility Supplier/bank karena SELECT RLS dibatasi
  ke role pengelola/Finance;
- Purchase legacy, Supplier Order, Goods Receipt, stock, dan AP tidak diubah.

## Urutan Manual

1. Jalankan migration:
   `supabase/migrations/20260721230000_g2_phase6_supplier_foundation.sql`.
2. Jika sukses, jalankan postflight:
   `supabase/diagnostics/g2_phase6_supplier_foundation_postflight.sql`.
3. Expected: 9 baris dan seluruhnya `PASS`.
4. Jalankan behavioral test:
   `supabase/tests/g2_phase6_supplier_foundation_tests.sql`.
5. Expected: query sukses dan notice terakhir menyatakan `TEST PASSED`.
6. Database gate selesai. Lanjutkan API/UI melalui
   `G2_PHASE7_SUPPLIER_API_UI_ROLLOUT.md`.

## Stop Condition

- Jangan menjalankan migration dua kali.
- Jika migration menampilkan `G2_PHASE6_STATE_CHANGED`, hentikan dan kirim
  jumlah Purchase row; jangan menghapus Purchase untuk melewati guard.
- Jika migration gagal, transaction rollback otomatis; jangan jalankan
  postflight/test.
- Jika ada postflight `FAIL`, jangan lanjut ke API/UI Supplier.
- Jika behavioral test gagal, kirim error persis; fixture tetap rollback.
- Setelah migration sukses, file migration tidak boleh diedit. Koreksi harus
  memakai forward migration baru.

## Belum Termasuk

- smoke test API dan UI Supplier/Product-Supplier (fase 7);
- Supplier Order, penerimaan barang, Return Supplier, AP, dan payment;
- update `last_purchase_price` dari invoice Finance;
- import/export Supplier;
- perubahan stok atau Opening Stock;
- deployment Vercel.

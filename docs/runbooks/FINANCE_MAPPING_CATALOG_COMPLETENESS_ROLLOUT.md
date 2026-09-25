# Finance Mapping Catalog Completeness Rollout

Status: `LOCAL READY` setelah seluruh local gate lulus; Production belum disentuh.

## Urutan wajib

Hentikan rollout pada SQL error, `BLOCKER`, atau `FAIL`.

1. Jalankan `supabase/diagnostics/finance_mapping_catalog_completeness_preflight.sql`.
2. Pastikan seluruh row selain `INFO` berstatus `PASS` dan
   `finance_mapping_catalog_runtime_resolution` mempunyai resolved row nonzero.
3. Jalankan migration
   `supabase/migrations/20260924120000_finance_mapping_catalog_completeness.sql`.
4. Jalankan `supabase/tests/finance_mapping_catalog_completeness_behavior.sql`.
5. Jalankan `supabase/diagnostics/finance_mapping_catalog_completeness_postflight.sql`.
6. Deploy client commit yang memuat Finance Master API/UI baru.
7. Lakukan authenticated smoke berikut.

## Authenticated smoke

Untuk KMS, SMS, dan LSM:

1. Login sebagai Finance/Admin yang mempunyai akses `finance.master_data`.
2. Buka Finance → Kategori & COA → Kelengkapan mapping.
3. Pastikan data Company tidak bercampur dan Retur Pembelian menampilkan:
   Persediaan serta AP provisional sebagai wajib; AP final, Piutang Refund
   Supplier, PPV, dan Pajak Masukan sebagai sesuai kondisi.
4. Pastikan status/akun efektif sesuai rule atau fallback yang sedang berlaku.
5. Buka editor Mapping akun dan pastikan fungsi optional suatu event ikut muncul.
6. Login sebagai role tanpa hak kelola; data boleh mengikuti capability VIEW,
   tetapi tombol mutation tidak boleh muncul/berhasil.
7. Buat satu mapping Draft/Active hanya bila Finance memang menginstruksikan;
   verifikasi versioning dan audit existing. Jangan mengganti mapping hanya untuk
   smoke.
8. Jalankan satu Retur Supplier representatif yang memang diperlukan bisnis,
   lalu pastikan Event/Journal tetap balanced dan source-linked. Ini adalah gate
   smoke runtime, bukan bagian otomatis migration metadata.

## Expected status

- Setelah langkah 1–5: `DATABASE LIVE`, belum `CLIENT DEPLOYED` atau `SMOKE PASS`.
- Setelah deploy: `CLIENT DEPLOYED`, belum `SMOKE PASS` sebelum langkah 7 selesai.
- `UAT PASS` hanya setelah user Finance menerima nama, status, dan akun efektif.

## Forward fix

- Jangan rollback jurnal, Return, COA, atau mapping.
- Jika catalog salah, buat migration baru yang mengoreksi array metadata.
- Jika client bermasalah, rollback client saja; API field baru bersifat additive.

## Scope yang tetap tertunda

- Supplier Refund Receipt/Offset;
- Gross Sales Discount;
- bulk mapping dari workbook Finance.

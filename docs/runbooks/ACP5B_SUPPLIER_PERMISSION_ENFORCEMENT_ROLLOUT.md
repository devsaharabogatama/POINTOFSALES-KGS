# ACP-5B Supplier Permission Enforcement Rollout

**Status:** LOCAL READY — manual Supabase rollout dan authenticated smoke pending  
**Gate:** ACP-5B, bagian dari ACP-5 Contacts/Purchase/Sales  
**Permission key:** `contacts.suppliers`

## Outcome

Supplier dan Product-Supplier menjadi satu workspace Contacts yang dijaga
capability `VIEW`, `MANAGE`, `EXPORT`, dan `IMPORT`. Browser tidak lagi membaca
atau menulis empat tabel Supplier secara langsung. Purchase, Finance, Product,
Goods Receipt, dan POS Purchase Return tetap memakai reference RPC sempit yang
mengotorisasi workflow masing-masing; pembatasan Contacts tidak otomatis
mematikan workflow lain yang memang diizinkan.

Perubahan ini tidak mengubah status, Stock/FIFO, AP, Supplier Invoice, Supplier
Payment, atau histori Purchase. Legacy writer tetap tersedia hanya untuk
private import core/service role, bukan browser.

## Urutan Eksekusi Wajib

Jalankan satu per satu di Supabase SQL Editor. Berhenti pada error atau satu
row `FAIL`.

1. Migration:
   `supabase/migrations/20260812230000_acp_phase5b_supplier_permission_enforcement.sql`
2. Postflight:
   `supabase/diagnostics/acp_phase5b_supplier_permission_postflight.sql`
3. Behavioral test rollback-only:
   `supabase/tests/acp_phase5b_supplier_permission_tests.sql`
4. Supplier foundation regression:
   `supabase/tests/g2_phase6_supplier_foundation_tests.sql`
5. Product-Supplier import regression:
   `supabase/tests/g2_phase44_product_supplier_import_tests.sql`
6. Supplier Order regression:
   `supabase/tests/g5_phase2_stock_request_supplier_order_tests.sql`
7. Goods Receipt regression:
   `supabase/tests/g5_phase5_goods_receipt_foundation_tests.sql`
8. Purchase Return regression:
   `supabase/tests/g5_phase8_purchase_return_foundation_tests.sql`
9. Supplier Invoice regression:
   `supabase/tests/g5_phase11_supplier_invoice_matching_tests.sql`
10. Supplier Payment regression:
    `supabase/tests/g5_phase14_supplier_payment_tests.sql`
11. Ulangi postflight pada langkah 2 sebagai closing evidence.

Migration sudah transactional. Jika gagal sebelum `COMMIT`, jangan mengedit
migration yang sudah pernah berhasil diterapkan; buat forward fix baru.

## Hasil yang Diharapkan

- seluruh postflight `PASS`;
- behavior menampilkan notice `TEST PASSED` dan berakhir `ROLLBACK`;
- `contacts.suppliers` berstatus `ENFORCED` dengan empat capability;
- `authenticated` tidak mempunyai direct SELECT/write pada Supplier,
  Product-Supplier, atau audit;
- legacy `save_supplier` dan `save_product_supplier` tidak executable oleh
  `authenticated`;
- Supplier management, export, import, Purchase, Goods Receipt/Return, Supplier
  Invoice, dan Supplier Payment tetap berjalan lewat RPC yang sesuai;
- Company B tidak melihat Supplier Company A.

## Authenticated Smoke Setelah SQL PASS

Restart Backoffice dan PWA agar schema cache dan bundle terbaru dipakai.

1. Owner/Admin tanpa override: buka Supplier, create/edit Supplier, pasang
   Product-Supplier, export dan import template Supplier.
2. `LIHAT_SAJA`: list/detail terbuka; create/edit/import/export ditolak sesuai
   capability preset.
3. `TANPA_AKSES`: card, Fast Link, direct URL, API, dan management RPC ditolak.
4. Finance/Accounting: dapat memakai reference Supplier pada Invoice/Payment,
   tetapi tidak dapat mengubah Supplier.
5. Store Manager yang Contacts-nya dibatasi tetap dapat memakai Supplier Order
   jika permission Purchase-nya mengizinkan.
6. Kasir dengan sesi aktif: Goods Receipt hanya menampilkan Supplier dari Order
   Store tersebut; Purchase Return hanya menampilkan Supplier dari Receipt
   posted Store tersebut.
7. Switch Company A/B: data Supplier, bank reference, Product-Supplier, export,
   dan dokumen reference tidak bocor antar-Company.

## Compatibility dan Forward Fix

- Tidak ada backfill business row.
- Code Supplier existing tetap dipertahankan; UI tetap tidak meminta code.
- Import core tetap dapat memakai writer lama melalui SECURITY DEFINER owner,
  sedangkan entrypoint browser wajib `IMPORT`.
- Bila UI gagal setelah SQL PASS, jangan mengembalikan direct table grant.
  Perbaiki consumer ke RPC sempit atau buat forward migration privilege/RPC.
- Rollback operasional aman adalah mengembalikan catalog key ke `SHADOW` dan
  mengembalikan consumer app bersama privilege yang cocok melalui forward fix;
  audit/override tidak dihapus.

## Gate Berikutnya

Setelah seluruh SQL dan smoke di atas PASS, lanjut ACP-5C Purchase permission
preflight. Jangan meng-enforce Purchase/Sales/Finance key dari fase ini.

# ACP-5C Supplier Order Permission Enforcement Rollout

**Status:** LOCAL READY — manual Supabase rollout and authenticated smoke pending  
**Gate:** ACP-5C, bagian dari ACP-5 Contacts/Purchase/Sales  
**Permission key:** `purchase.supplier_orders`

## Outcome

Workspace Supplier Order Backoffice dijaga capability `VIEW`, `CREATE_DRAFT`,
`EDIT_DRAFT`, `POST`, dan `CANCEL_FINAL`. Browser tidak lagi membaca atau
menulis tujuh tabel Stock Request/Supplier Order secara langsung.

Authority lain tetap terpisah:

- Cashier membuat dan submit Stock Request melalui open session miliknya;
- Goods Receipt menerima Order yang eligible hanya untuk Store open session;
- POS Purchase Return hanya menerima label Order dari Receipt posted Store;
- Purchase Return Backoffice tetap `SHADOW` dan tidak ikut dienforce;
- Supplier Order tidak membuat Stock, FIFO, AP, payment, atau journal.

Preset `OPERASIONAL` dapat melihat dan membuat/mengedit Draft, tetapi tidak
dapat Post atau Cancel Final. Preset `LIHAT_SAJA` hanya melihat dan
`TANPA_AKSES` tidak melihat launcher/API/workspace.

## Urutan Eksekusi Wajib

Jalankan satu per satu di Supabase SQL Editor. Berhenti pada error atau satu
row `FAIL`.

1. Migration:
   `supabase/migrations/20260813000000_acp_phase5c_supplier_order_permission_enforcement.sql`
2. Postflight:
   `supabase/diagnostics/acp_phase5c_supplier_order_permission_postflight.sql`
3. Behavioral test rollback-only:
   `supabase/tests/acp_phase5c_supplier_order_permission_tests.sql`
4. Stock Request/Supplier Order regression:
   `supabase/tests/g5_phase2_stock_request_supplier_order_tests.sql`
5. Goods Receipt regression:
   `supabase/tests/g5_phase5_goods_receipt_foundation_tests.sql`
6. Purchase Return regression:
   `supabase/tests/g5_phase8_purchase_return_foundation_tests.sql`
7. Supplier permission regression:
   `supabase/tests/acp_phase5b_supplier_permission_tests.sql`
8. Ulangi postflight pada langkah 2 sebagai closing evidence.

Migration transactional. Jika gagal sebelum `COMMIT`, perbaiki file sebelum
mencoba lagi. Jika ledger migration sudah tercatat, jangan edit migration yang
sudah diterapkan; gunakan forward fix.

## Hasil yang Diharapkan

- seluruh postflight `PASS`;
- behavior dan regression menampilkan `TEST PASSED` lalu `ROLLBACK`;
- `purchase.supplier_orders` berstatus `ENFORCED`;
- `authenticated` tidak mempunyai direct SELECT/write pada Request, Order,
  allocation, atau audit;
- Backoffice memakai composed workspace RPC;
- Cashier Request/Receipt tetap bekerja melalui RPC open-session sempit;
- Confirm tetap idempotent dan Order tetap zero-effect;
- Company B tidak melihat Request/Order Company A.

## Authenticated Smoke Setelah SQL PASS

Restart Backoffice dan PWA agar schema cache serta bundle terbaru dipakai.

1. Owner/Admin tanpa override: Supplier Order tampil, Draft dapat dibuat dan
   Confirm berhasil.
2. `OPERASIONAL`: workspace dan tombol Buat Order tampil; Draft tersimpan;
   tombol Confirm tidak tampil dan direct RPC Confirm ditolak.
3. `LIHAT_SAJA`: workspace tampil read-only tanpa Buat/Confirm.
4. `TANPA_AKSES`: card, Fast Link, direct URL/API, dan composed RPC ditolak.
5. Cashier aktif: buat dan submit Stock Request; hanya request miliknya pada
   Store aktif yang tampil.
6. Setelah Admin Confirm: Goods Receipt Cashier Store terkait menampilkan
   Order dan line; Cashier Store lain tidak melihatnya.
7. Purchase Return existing tetap terbuka menurut authority lamanya.
8. Switch Company A/B: Request, Order, allocation, Supplier, Store, dan
   Warehouse tidak bocor.

## Compatibility dan Forward Fix

- Tidak ada backfill business row.
- Core legacy dipindahkan ke schema `private`; public signature tetap kompatibel
  melalui wrapper capability-aware.
- `save_stock_request` dan `submit_stock_request` tetap entrypoint Cashier.
- Jika UI gagal setelah SQL PASS, jangan mengembalikan direct table grant.
  Perbaiki consumer ke RPC sempit atau buat forward migration.
- Rollback operasional dilakukan melalui forward fix yang mengembalikan key ke
  `SHADOW` beserta app/privilege yang konsisten; dokumen dan audit tidak dihapus.

## Gate Berikutnya

Setelah seluruh SQL dan smoke PASS, lanjut ACP-5D Purchase Return sebagai
SELECT-only preflight. Jangan meng-enforce Sales/Finance dari fase ini.

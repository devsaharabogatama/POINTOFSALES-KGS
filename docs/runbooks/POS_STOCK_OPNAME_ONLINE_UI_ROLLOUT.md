# POS Stock Opname Online UI Rollout

## Status

`PARTIAL_REVIEW_RUNTIME_LOCAL_READY_MANUAL_SUPABASE_AND_STAGING_SMOKE_PENDING`

Behavioral create pada gudang dengan stok minus menemukan constraint legacy
yang menolak snapshot stok sistem bertanda. Workspace awal bukan UAT-ready
sampai forward-fix `20260902110000` dan behavioral rollback di bawah lulus.

Slice ini membuka UI blind count Stock Opname pada PWA secara online. Ia tidak
mengubah lifecycle hitung, Adjustment, Stock, FIFO, Movement, atau Finance yang
sudah dijaga runtime G3/ACP-4G.

## Perubahan

- RPC `get_pos_stock_opname_workspace()` menampilkan hanya:
  - sesi milik actor pada Company dan Gudang yang masih boleh dihitung;
  - nomor, status, cakupan, catatan, versi, waktu, dan jumlah status baris;
  - referensi Gudang, Kategori, Product, SKU, dan Base UOM yang sempit.
- RPC workspace tidak mengembalikan physical quantity lama, system/expected
  quantity, variance, difference, FIFO, HPP, atau nilai rupiah.
- PWA mempunyai menu `Opname` online dengan create/edit Draft, start, blind
  count per Product, review hitungan sendiri, recount window, partial complete,
  cancel, list, dan resume setelah refresh.
- Partial complete memerlukan minimal satu hasil `COUNTED`. Baris `PENDING` atau
  `RECOUNT_REQUIRED` hanya dapat dilewati setelah konfirmasi eksplisit dan akan
  menjadi `SKIPPED`. Status tersebut tidak dianggap nol dan tidak masuk
  Adjustment, Stock, FIFO, Movement, atau Finance.
- `STOCK_OPNAME` menjadi opsi tampil/sembunyi pada pengaturan Terminal POS.
- Posting dan review tetap hanya di Backoffice.

## Urutan manual Supabase

Jalankan satu per satu dan berhenti pada error, `BLOCKER`, atau `FAIL`:

1. [`pos_stock_opname_ui_preflight.sql`](../../supabase/diagnostics/pos_stock_opname_ui_preflight.sql)
2. [`20260902100000_pos_stock_opname_online_workspace.sql`](../../supabase/migrations/20260902100000_pos_stock_opname_online_workspace.sql)
3. [`stock_opname_negative_stock_compatibility_preflight.sql`](../../supabase/diagnostics/stock_opname_negative_stock_compatibility_preflight.sql)
4. [`20260902110000_stock_opname_negative_stock_compatibility.sql`](../../supabase/migrations/20260902110000_stock_opname_negative_stock_compatibility.sql)
5. [`stock_opname_negative_stock_compatibility_behavior.sql`](../../supabase/tests/stock_opname_negative_stock_compatibility_behavior.sql)
6. [`stock_opname_negative_stock_compatibility_postflight.sql`](../../supabase/diagnostics/stock_opname_negative_stock_compatibility_postflight.sql)
7. [`stock_opname_partial_review_preflight.sql`](../../supabase/diagnostics/stock_opname_partial_review_preflight.sql)
8. [`20260902120000_stock_opname_partial_review_runtime.sql`](../../supabase/migrations/20260902120000_stock_opname_partial_review_runtime.sql)
9. [`stock_opname_partial_review_behavior.sql`](../../supabase/tests/stock_opname_partial_review_behavior.sql)
10. [`stock_opname_partial_review_postflight.sql`](../../supabase/diagnostics/stock_opname_partial_review_postflight.sql)
11. [`pos_stock_opname_ui_contract_tests.sql`](../../supabase/tests/pos_stock_opname_ui_contract_tests.sql)
12. [`pos_stock_opname_ui_postflight.sql`](../../supabase/diagnostics/pos_stock_opname_ui_postflight.sql)
13. Ulangi postflight ACP-4G dari source terbaru:
   [`acp_phase4g_stock_opname_permission_postflight.sql`](../../supabase/diagnostics/acp_phase4g_stock_opname_permission_postflight.sql)

Preflight mengharapkan workspace `SETUP`; itu bukan blocker sebelum migration.
Preflight kompatibilitas mengharapkan constraint state `SETUP`; itu bukan
blocker sebelum forward-fix. Behavioral wajib menampilkan `TEST PASSED` dan
melakukan `ROLLBACK`. Kedua postflight harus seluruhnya `PASS/INFO`.

## Staging smoke

1. Deploy/restart PWA dan Backoffice staging, lalu hard refresh.
2. Login dengan Cashier yang mempunyai sesi `OPEN` serta assignment Store dan
   Gudang yang valid.
3. Pastikan menu `Opname` tampil dan menjadi disabled saat browser offline.
4. Buat Draft untuk scope `ALL`, `CATEGORY`, dan `SELECTED`; batalkan dua fixture
   yang tidak dilanjutkan.
5. Refresh browser dan pastikan Draft milik actor dapat dilanjutkan.
6. Mulai hitung; pastikan UI tidak pernah menampilkan stok sistem, hasil sesi
   lain, selisih, FIFO, HPP, atau nilai. Angka milik counter pada sesi aktif
   harus tetap terlihat setelah refresh dan dapat diperbaiki.
7. Simpan jumlah nol, integer, dan decimal sesuai precision Base UOM. Scroll
   mouse tidak boleh mengubah angka.
8. Buat movement pada salah satu Product selama count window. Baris harus menjadi
   `Perlu hitung ulang`, lalu dapat dibuka dan dihitung ulang.
9. Hitung satu Product sebagai nol, biarkan minimal satu Product kosong, lalu
   buka **Review hasil**. Pastikan nol tampil sebagai hasil eksplisit dan baris
   kosong tercantum akan dilewati.
10. Submit tanpa checklist harus ditolak. Setelah checklist, sesi menjadi
    `COMPLETED`; Backoffice menampilkan jumlah dihitung dan `SKIPPED` terpisah.
11. Post dari Backoffice dan buktikan hanya line `COUNTED` yang masuk Adjustment;
    `SKIPPED` tidak mengubah Stock/FIFO/Movement/Finance.
12. Dari Backoffice minta recount satu Product `COUNTED`. Pastikan sesi muncul kembali
    `COUNTING` pada POS actor pembuat.
13. Selesaikan recount dan Post dari Backoffice. Periksa Adjustment, Stock Real,
    Movement, FIFO, dan report Opname menunjuk dokumen yang sama.
14. Negative smoke:
    - actor Company lain;
    - Gudang Store lain;
    - preset `LIHAT_SAJA` dan `TANPA_AKSES`;
    - stale `masterVersion`;
    - exact refresh/retry;
    - terminal dengan `Stock Opname` disembunyikan.

## Compatibility dan rollback

- Tidak ada backfill dan tidak ada row Stock Opname yang diubah migration.
- Snapshot `system_qty`, `system_qty_at_start`, dan `expected_qty_at_count`
  sengaja bertanda agar stok minus dapat dihitung. Hanya input fisik yang tetap
  wajib nol atau positif.
- Seluruh RPC mutation canonical mempertahankan signature lama.
- RPC complete lama tetap ada untuk compatibility. POS baru memakai
  `complete_stock_opname_partial` agar pengabaian baris tidak pernah implisit.
- UI lazy-loaded sehingga checkout/cart tidak memuat bundle Opname sebelum menu
  dibuka.
- Offline Opname tetap ditutup. Jika koneksi putus, input yang belum mendapat
  respons tidak dianggap tersimpan dan tidak masuk queue offline.
- Bila smoke UI gagal, sembunyikan `Stock Opname` pada Terminal atau rollback
  deployment PWA. RPC read-only dapat dibiarkan dan diperbaiki forward-only;
  jangan membuka direct table read.

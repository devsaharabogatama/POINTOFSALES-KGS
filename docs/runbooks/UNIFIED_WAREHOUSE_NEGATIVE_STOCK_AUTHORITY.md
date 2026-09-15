# Unified Warehouse Negative Stock Authority — Cutover Step 4A/6

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.

Target wajib hanya project Development `fkywtxucmyjvpwdiqpix`. Jangan jalankan
di staging/production. Paket ini belum membuka Apply atau mengganti mode Company.

## Kontrak bisnis

- Gudang sale-source aktif dengan `allow_negative_stock=true` adalah satu-satunya
  izin untuk reservasi/penjualan minus dari POS maupun Backoffice.
- Tidak ada gate Company feature, terminal/toko, izin user, limit user/Company,
  atau alasan operasional untuk transaksi baru.
- Role transaksi, tenant/company scope, warehouse scope, idempotency, Stock,
  FIFO provisional cost, replenishment, Finance, dan audit tetap berlaku.
- Evidence historis `LEGACY_USER_POLICY` tidak ditulis ulang atau dihapus.
  Evidence baru memakai `WAREHOUSE` + versi master Gudang.

## Urutan manual

1. Jalankan [preflight](../../supabase/diagnostics/unified_warehouse_negative_stock_authority_preflight.sql) utuh.
2. Stop pada SQL error atau `BLOCKER`.
3. Jalankan [migration 20260910153000](../../supabase/migrations/20260910153000_unified_warehouse_negative_stock_authority.sql) utuh satu kali.
4. Jalankan [behavioral rollback](../../supabase/tests/unified_warehouse_negative_stock_authority_behavior.sql).
   Test tidak membutuhkan Draft, Order, Reservation, atau sesi operasional.
   Ia memakai master POS aktif, lalu membuat actor, sesi OPEN, Draft lewat RPC
   canonical dengan fulfillment `DELIVERY`, payment intent, dan shortage
   deterministik sendiri; seluruh fixture serta hasil uji diakhiri `ROLLBACK`.
5. Jalankan [postflight](../../supabase/diagnostics/unified_warehouse_negative_stock_authority_postflight.sql) utuh.
6. Kirim seluruh result set. User telah mengonfirmasi tidak ada `FAIL`; converter
   Step 4B dapat dilanjutkan. Authenticated smoke/UAT tetap manual.

Attempt migration pertama gagal pada guard dan seluruh transaksi rollback.
Root cause-nya adalah target fungsi lokal yang salah: logika Reservation berada
di `private.confirm_pos_sales_order_core`, sedangkan
`private.confirm_pos_sales_order_before_revision_core` adalah wrapper komposisi
Invoice identity, dokumen, procurement, dan payment. Paket terkoreksi mengganti
hanya core Reservation serta menguji wrapper tersebut tetap utuh.

Attempt kedua juga rollback pada marker Dispatch. Fungsi Dispatch aktif pernah
direkonstruksi oleh forward-fix `20260901100000` menggunakan
`pg_get_functiondef`/`EXECUTE`, sehingga whitespace literal source awal tidak
lagi menjadi anchor yang stabil. Paket terbaru memakai empat anchor semantik
sempit dan mewajibkan masing-masing match tepat satu kali sebelum mengganti
fungsi; drift logika tetap menghentikan migration.

## Behavioral dan smoke setelah SQL PASS

- Warehouse OFF menolak shortage tanpa meninggalkan Reservation/Stock effect.
- Warehouse ON menerima transaksi yang sama tanpa permission user dan alasan.
- Exact retry tidak menggandakan Reservation/authorization/allocation.
- Dispatch minus tetap menghasilkan Movement, provisional FIFO cost, dan
  negative allocation; replenishment tetap merekonsiliasi biaya.
- Uji tenant kedua dan gudang lain untuk memastikan opt-in tidak bocor.

Catatan gap terpisah: runtime ODR `ensure_confirmed_order_documents` membuat
Delivery Document untuk `PICKUP` lalu menetapkan `sj_required=true`, sedangkan
constraint header hanya mengizinkan bentuk itu setelah `document_status=POSTED`.
Behavioral authority ini tidak mengubah atau menguji flow `PICKUP`; konflik
tersebut harus mendapat forward-fix tersendiri setelah impact audit dokumen.

## Forward-fix / rollback

Migration tidak dihapus setelah applied. Bila runtime gagal, nonaktifkan
`allow_negative_stock` pada Gudang terkait untuk menghentikan shortage baru,
pertahankan histori, lalu buat migration forward-fix. Jangan mengembalikan
constraint lama karena row `WAREHOUSE` tidak mempunyai permission/reason legacy.

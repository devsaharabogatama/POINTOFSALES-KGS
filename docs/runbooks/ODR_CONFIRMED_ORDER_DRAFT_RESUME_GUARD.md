# ODR Confirmed Order versus Draft Resume Guard

## Masalah

Order yang sudah dikonfirmasi tetap memakai `document_status='DRAFT'` selama
stok dan Finance menunggu Dispatch. Daftar Draft legacy hanya memeriksa kolom
tersebut, sehingga Order `RESERVED` ikut tampil dan dapat dibuka pada editor
Draft. Repricing kemudian mencoba menghapus `sale_stock_requirements` yang
sudah direferensikan `sales_stock_reservation_lines` dan dihentikan FK.

## Kontrak perbaikan

- Draft yang editable hanya `DRAFT_INPUT` atau `SCHEDULED` dengan
  `confirmed_at IS NULL`.
- Order confirmed/reserved tidak dihapus dan reservasinya tidak dilepas.
- Save Draft menolak Order confirmed sebelum repricing atau delete requirement.
- Order confirmed dilanjutkan dari daftar Order dan workflow Inventory.
- FK tetap `ON DELETE RESTRICT`; tidak ada direct table write baru.

## Urutan rollout manual

1. Jalankan `supabase/diagnostics/odr_confirmed_order_draft_resume_preflight.sql`.
2. Stop hanya pada `BLOCKER`. Status `SETUP` pada confirmed Order yang terkena
   predicate Draft lama adalah scope yang diperbaiki migration.
3. Jalankan
   `supabase/migrations/20260830100000_odr_confirmed_order_draft_resume_guard.sql`.
4. Jalankan
   `supabase/tests/odr_confirmed_order_draft_resume_postflight.sql`.
5. Stop jika ada `FAIL`.
6. Deploy/restart PWA, lalu hard refresh.

## Smoke manual

1. Buka daftar Draft: Order yang sudah mempunyai Invoice/reservasi tidak boleh
   muncul.
2. Draft input biasa tetap dapat dibuka, diubah, disimpan, dan dikonfirmasi.
3. Order reserved tetap muncul pada panel Order dan reservasi Stock Real tidak
   berubah.
4. Tab lama yang masih memegang Order confirmed harus menerima pesan
   `Order sudah dikonfirmasi...`, bukan error FK mentah.

## Rollback operasional

Jangan menghapus reservasi atau menonaktifkan FK. Jika rollout bermasalah,
hentikan edit Draft sementara dan gunakan forward-fix pada wrapper/list RPC;
histori Order dan Reservation yang sudah ada harus dipertahankan.

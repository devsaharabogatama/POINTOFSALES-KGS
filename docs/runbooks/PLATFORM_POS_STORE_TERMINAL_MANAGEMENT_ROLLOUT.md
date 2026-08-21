# Platform POS Store dan Terminal Management

## Tujuan

Menu **Platform > Point of Sales** mengelola Toko dan Terminal POS pada Company
aktif. PWA tetap memakai satu login: user multi-Company memilih Company sebelum
membuka sesi, lalu memilih Terminal dan Gudang penjualan yang tersedia.

## Otoritas dan invariant

- Mutation hanya lewat RPC guarded; direct browser write tetap ditutup.
- Hanya Super Admin atau Owner/Admin Company aktif yang dapat mengelola data.
- Kode Toko dan Terminal immutable; update memakai optimistic version.
- Audit Store/Terminal append-only.
- Terminal dengan sesi terbuka tidak dapat diubah. Terminal dengan riwayat sesi
  tidak dapat dipindah Toko.
- Toko tidak dapat dinonaktifkan selama masih mempunyai sesi, Terminal aktif,
  atau Gudang aktif yang terikat.
- PWA tidak dapat mengganti Company saat sesi kasir masih terbuka. Pergantian
  Toko dilakukan lewat pilihan Terminal sebelum membuka sesi baru.

## Urutan rollout

1. Jalankan `supabase/migrations/20260821120000_platform_pos_store_terminal_management.sql`.
2. Jalankan `supabase/diagnostics/platform_pos_store_terminal_management_postflight.sql`;
   seluruh hasil selain `INFO` wajib `PASS`.
3. Jalankan `supabase/tests/platform_pos_store_terminal_management_tests.sql`;
   hasil akhir wajib `PASS` dan fixture di-rollback.
4. Deploy Backoffice, lalu smoke sebagai Owner/Admin: buat Toko dan Terminal.
5. Atur Gudang sumber penjualan melalui Inventory > Master Inventory dan assign
   user Store-scoped melalui Kontak > User & Akses.
6. Smoke PWA: pilih Company, Terminal berlabel Toko, dan Gudang; buka sesi dan
   pastikan Company terkunci; tutup sesi lalu coba Company/Terminal lain tanpa
   login ulang.

Migration additive terhadap flow sesi lama. Jika rollout bermasalah, gunakan
forward-fix; jangan menghapus identity Toko/Terminal yang sudah punya histori.

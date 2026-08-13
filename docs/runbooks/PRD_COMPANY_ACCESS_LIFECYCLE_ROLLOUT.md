# PRD Company Access Lifecycle Rollout

**Status:** DATABASE, POSTFLIGHT, DAN BEHAVIOR USER-PASS; UI SMOKE PENDING

## Outcome

Detail user sekarang mempunyai Company selector eksplisit. Role, Store, dan
pembatasan submodul selalu menampilkan nama Company yang sedang diatur. Role
dapat diperbarui dan membership dapat dicabut tanpa menghapus Auth identity,
histori transaksi, atau audit.

## Urutan rollout

1. Jalankan `supabase/migrations/20260813140000_prd_company_access_lifecycle.sql`.
2. Jalankan `supabase/diagnostics/prd_company_access_lifecycle_postflight.sql`.
   Seluruh row selain inventory `INFO` wajib `PASS` dengan `violation_rows=0`.
3. Jalankan `supabase/tests/prd_company_access_lifecycle_tests.sql`.
   File memakai data sintetis, `SET LOCAL ROLE authenticated`, dan `ROLLBACK`.
4. Restart Backoffice lalu buka `Kontak -> Tim & Akses -> detail user`.
5. Pilih Company A dan Company B bergantian. Pastikan label `Sedang diatur`,
   role, Store, serta judul pembatasan submodul mengikuti pilihan tersebut.
6. Ubah role hanya pada Company B; Company A harus tidak berubah.
7. Cabut akses Company B melalui modal konfirmasi. User tidak lagi melihat B
   setelah refresh/login ulang, tetapi tetap dapat membuka Company A.
8. Jalankan postflight ulang, lalu ACP-7 dan PRD-1 consolidated preflight.

## Invariant

- Non-Super Admin hanya dapat mengelola Company aktifnya.
- Company Owner dapat mengelola target di bawah Owner; Company Admin hanya
  target di bawah Admin. Self-mutation ditolak.
- Owner aktif terakhir tidak dapat diturunkan atau dicabut.
- Cashier wajib memiliki satu Store aktif dalam Company yang sama.
- Cabut akses menonaktifkan Company dan Store membership secara atomic,
  membersihkan override aktif dengan append-only permission audit, memperbaiki
  default dan active Company context, serta menulis immutable assignment audit.
- Histori transaksi, dokumen, Stock, Finance, Auth identity, dan Profile tidak
  dihapus.

## Compatibility dan rollback

Flow `Tambah akses akun existing` lama tetap tersedia. Migration additive dan
tidak mengubah baseline role. Bila UI perlu ditarik, tutup route
`/api/staff/company-access` dan revoke dua RPC public; jangan menghapus audit
atau mengaktifkan membership lewat direct table mutation. Gunakan forward fix.

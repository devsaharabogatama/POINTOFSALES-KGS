# Company Document Logo Visibility Rollout

## Outcome

Owner atau Admin Company dapat mengaktifkan atau menonaktifkan logo header dan
stempel visual secara independen pada template print dan PDF Invoice serta Surat
Jalan. Stempel memakai file logo yang sama sebagai cap biru-transparan di area
tanda tangan Warehouse. Pengaturan berlaku per Company, dicatat ke audit
branding, dan tidak menghapus object logo. Logo pada navigasi aplikasi tetap
tampil.

Company existing menggunakan nilai awal logo header `TRUE` dan stempel `FALSE`,
sehingga rollout tidak mengubah hasil dokumen sebelum pengguna mengubah setting.

## Boundary

- Pengaturan hanya mengubah presentasi dokumen; snapshot Sale, nomor dokumen,
  lifecycle, Stock, Payment, Finance, dan permission dokumen tidak berubah.
- Unduh Surat Jalan satuan dan bulk ZIP memakai pengaturan yang sama.
- Pengaturan saat dokumen dicetak menjadi keputusan display terkini. Snapshot
  logo historis tidak dimutasi dan object yang pernah dirujuk tetap disimpan.
- Stempel adalah elemen visual template, bukan tanda tangan digital atau cap
  elektronik tersertifikasi.
- Mutation hanya tersedia untuk `COMPANY_OWNER` dan `COMPANY_ADMIN`, memakai
  optimistic `master_version`, exact retry, active Company, dan audit append-only.

## Urutan rollout

1. Jalankan
   `supabase/migrations/20260820110000_company_document_logo_visibility.sql`.
2. Jalankan
   `supabase/tests/company_document_logo_visibility_postflight.sql`.
   Seluruh baris wajib `PASS` dengan `violation_rows = 0`.
3. Jalankan
   `supabase/tests/company_document_logo_visibility_behavior.sql`.
   Script harus selesai tanpa exception dan selalu berakhir dengan `ROLLBACK`.
4. Deploy Backoffice dari commit yang memuat migration ini, lalu hard refresh.

Jangan menjalankan behavioral test sebelum migration dan postflight lulus.

## Smoke test staging

1. Login sebagai Owner/Admin dan buka **Platform -> Logo Perusahaan**.
2. Pastikan logo sudah diunggah. Matikan **Tampilkan logo pada dokumen** dan
   aktifkan **Tampilkan stempel pada dokumen**.
3. Buka satu Invoice: print dan PDF harus tanpa logo header, tetapi mempunyai
   stempel biru-transparan di area Warehouse.
4. Buka satu Surat Jalan: print, PDF satuan, dan PDF di dalam bulk ZIP harus
   mengikuti kombinasi logo/stempel yang sama.
5. Pastikan logo di samping nama Company tetap ada.
6. Aktifkan kembali logo header dan matikan stempel, lalu ulangi satu Invoice
   serta satu Surat Jalan; logo harus kembali tanpa upload ulang dan cap hilang.
7. Ganti Company aktif dan pastikan nilai tidak bocor antar-Company.
8. Login sebagai pengguna non-Owner/Admin: nilai dapat dipakai saat render,
   tetapi sakelar tidak dapat diubah.

## Compatibility dan forward fix

- Tidak ada object Storage yang dihapus oleh perubahan visibility.
- Client lama mengabaikan field baru dan tetap menampilkan logo seperti semula.
- Client baru memakai fallback logo `TRUE` dan stempel `FALSE` bila dipasang
  sebelum migration, tetapi
  mutation baru belum boleh dipakai sebelum migration selesai.
- Jika smoke gagal, jangan menghapus kolom atau histori audit. Kembalikan logo
  ke `TRUE` dan stempel ke `FALSE`, pertahankan migration ledger, lalu lakukan
  forward fix pada renderer/RPC.

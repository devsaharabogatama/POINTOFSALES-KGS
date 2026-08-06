# G4 Phase 44 — Cash Deposit Operational UI

## Outcome

Phase 44 membuka UI online untuk lifecycle Setor Kas Phase 43 tanpa schema baru:

- Kasir dapat memilih satu atau beberapa Cashier Session `CLOSED` pada Store aktif;
- saldo yang ditahan untuk sesi berikutnya mengurangi expected setoran;
- tujuan Bank/Brankas, nominal aktual, waktu, bukti, dan catatan dikirim ke guarded RPC;
- Submit mengunci sesi sampai review selesai;
- Finance Backoffice membaca detail per sesi dan melakukan Approve/Reject;
- Approve memfinalkan alokasi dan membuat Financial Event `HOLD` sesuai Phase 43.

Bank statement matching, variance resolution, Offline Deposit, correction/reversal,
dan jurnal final G6 tetap tertutup.

## Evidence lokal

- PWA `npm.cmd run lint`: PASS;
- PWA `npm.cmd run build`: PASS;
- Backoffice `npm.cmd run lint`: PASS;
- Backoffice `npm.cmd run build`: PASS;
- route produksi terdeteksi:
  - `GET /api/finance/cash-deposits`;
  - `POST /api/finance/cash-deposits/[id]/review`.

Approve tidak meminta atau mengirim alasan. Field alasan hanya muncul dan wajib
pada aksi Reject.

## Smoke test authenticated

### 1. Buat setoran di PWA

1. Login sebagai Kasir/Manager yang memiliki Store dan Terminal aktif.
2. Pastikan minimal satu Session sudah `CLOSED` dan belum dialokasikan ke setoran lain.
3. Klik **Setor Kas** pada header PWA. Tombol tetap tersedia walau tidak ada Session `OPEN`.
4. Pilih satu atau beberapa sesi.
5. Bila sebagian kas menjadi modal sesi berikutnya, isi **Saldo sesi berikutnya**.
6. Pilih Bank atau Brankas, isi tujuan, nominal aktual, waktu, dan bukti bila diwajibkan policy Store.
7. Centang konfirmasi lalu klik **Simpan & Ajukan**.
8. Pastikan notifikasi sukses muncul dan sesi tersebut tidak lagi eligible pada dokumen baru.

### 2. Review di Backoffice

1. Login sebagai `COMPANY_OWNER`, `COMPANY_ADMIN`, atau `FINANCE` pada Company yang sama.
2. Buka **Finance > Setor Kas**.
3. Buka dokumen `Menunggu review`; cocokkan sesi, kas tutup, alokasi sebelumnya,
   saldo berikutnya, expected, aktual, selisih, tujuan, dan bukti.
4. Approve dokumen yang valid menggunakan dialog konfirmasi aplikasi.
5. Pastikan status menjadi `Disetujui` dan dokumen memiliki efek final server.
6. Ulangi dengan dokumen lain untuk Reject; alasan wajib dan sesi harus kembali eligible.

### 3. Negative path

- Accounting dapat membaca tetapi tidak memperoleh tombol Approve/Reject.
- Kasir lintas Store/Company tidak dapat memasukkan Session yang tidak berada dalam scope.
- Actual nol, tujuan kosong, bukti non-HTTPS, saldo berikutnya >= kas tersedia,
  stale version, dan double submit harus ditolak.
- Escape menutup detail/dialog paling atas; tidak ada browser `prompt`/`confirm`.

## Compatibility

- migration Phase 43 tidak diubah atau diulang;
- direct browser write ke tabel Deposit tetap tertutup;
- UUID hanya dipakai internal dan tidak ditampilkan sebagai identitas operasional;
- legacy bank deposit tidak dicutover oleh UI ini.

## Next safe step

Setelah smoke di atas lulus, jalankan closing postflight Phase 43 untuk memastikan
Session lock, Deposit allocation, Financial Event, audit, dan variance exception
tetap konsisten. Setelah itu lanjutkan gate berikut pada roadmap; jangan membuka
bank matching atau G6 secara implisit.

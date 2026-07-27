# G2 Phase 15 — Payment Method API/UI Smoke

## Outcome

Guarded API dan Backoffice UI untuk membaca, membuat, serta mengubah Payment
Method canonical. UI tidak mengaktifkan master ini pada checkout.

## Prasyarat

- migration `20260722120000` applied;
- 13/13 postflight PASS;
- behavioral test Payment Method PASS.

## Langkah manual

1. Restart Backoffice.
2. Buka menu **Metode Pembayaran**.
3. Pastikan default **Tunai** tampil aktif, default, dan berlaku semua toko.
4. Buat metode QRIS:
   - nama user-facing, misalnya `QRIS BCA`;
   - jalur `Clearing` bila settlement belum masuk bank;
   - pilih semua toko atau toko tertentu;
   - bukti opsional/wajib sesuai kebijakan;
   - aktifkan fee dan pilih penanggung serta formula bila diperlukan.
5. Edit nama/fee/cakupan toko lalu simpan.
6. Buat metode kedua dan tandai default; pastikan default lama berpindah.
7. Tekan `Esc` saat modal terbuka dan pastikan modal tertutup.
8. Buka menu existing lain untuk compatibility smoke.

## Expected

- nama metode tampil sebagai label utama; UUID/account-function internal tidak
  ditampilkan;
- duplicate nama/kode ditolak;
- metode specific-store wajib memilih minimal satu toko;
- fee hanya tersedia untuk Direct Bank/Clearing;
- default harus aktif dan Company tetap memiliki tepat satu default;
- role di luar Finance/Company management hanya dapat membaca;
- checkout existing tidak berubah.

## Evidence lokal

- `npm.cmd run lint`: PASS;
- `npm.cmd run build`: PASS;
- route build: `/api/master/payment-methods` dan
  `/api/master/payment-methods/[id]` terdeteksi dynamic;
- `git diff --check`: wajib tetap bersih sebelum handoff.

## Sisa gap

- effective-dated Store fee override dan resolver precedence;
- checkout/split-payment server resolver;
- offline cache/snapshot signing;
- settlement, actual fee, reconciliation, dan Finance posting.

Gap tersebut tidak boleh diimplementasikan sebagai kalkulasi client-side.

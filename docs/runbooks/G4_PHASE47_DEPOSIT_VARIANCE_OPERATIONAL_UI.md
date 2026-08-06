# G4 Phase 47 — Deposit Variance Operational UI

## Outcome

Phase ini menyambungkan foundation Phase 46 ke halaman Backoffice
`Finance > Selisih Setoran`. Tidak ada schema atau direct table write baru.
Semua mutation tetap melalui guarded RPC Phase 46, active Company, optimistic
`master_version`, exact idempotency key, role check, dan maker-checker server.

## Scope UI

- Accounting: read-only list, detail, riwayat allocation, dan status request.
- Finance, Company Owner/Admin, Super Admin: menetapkan penanggung jawab untuk
  setoran kurang dan mencatat penyelesaian sebagian/penuh.
- Company Owner/Admin dan Super Admin: review request yang dibuat user lain.
- keputusan biaya, pendapatan, write-off, dan koreksi source selalu masuk
  maker-checker; pembuat tidak dapat menyetujui request sendiri.
- modal menggunakan UI aplikasi dan dapat ditutup dengan `Escape`.
- UUID tetap tersembunyi; user melihat nomor Setoran, Store, nama user, nominal,
  status, alasan, referensi, dan bukti.

## Boundary

- `RECOVERED_FUNDS` dan `REFUND_TO_SOURCE` mencatat settlement sesuai account
  function yang dipilih, tetapi seluruh Financial Event masih `HOLD`.
- `SOURCE_CORRECTION` pada fase ini mencatat keputusan/audit resolution. Ia
  belum menjalankan reversal atau replacement dokumen sumber.
- bank statement matching, jurnal G6, offline Expense/Deposit, internal cash
  transfer, dan G5 Purchasing tetap tertutup.

## Local Evidence

Jalankan dari `backoffice/`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Expected: keduanya exit code `0`; build memuat route berikut:

- `/api/finance/deposit-variances`
- `/api/finance/deposit-variances/[id]/assign`
- `/api/finance/deposit-variances/[id]/resolve`
- `/api/finance/deposit-variance-resolutions/[id]/review`

## Authenticated Smoke Test

1. Restart Backoffice, login sebagai Finance, pilih Company aktif, lalu buka
   `Finance > Selisih Setoran`.
2. Pastikan hanya exception milik Company aktif yang tampil. Setoran `MATCHED`
   tidak boleh membuat exception.
3. Pada setoran kurang, tetapkan penanggung jawab dan alasan. Refresh dan
   pastikan status/nama tetap tersimpan.
4. Catat sebagian sebagai `Uang ditemukan / uang pengganti`; masukkan nominal,
   jalur Bank/Kas Utama/Kas Dalam Perjalanan, alasan, dan bila ada link HTTPS.
   Pastikan sisa berkurang satu kali walaupun tombol/retry tidak sengaja diulang.
5. Ajukan `Write-off` atau `Biaya perusahaan`. Pastikan status request
   `Menunggu review` dan nominal exception belum berubah.
6. Login sebagai Owner/Admin lain. Approve request tanpa alasan tambahan.
   Pastikan allocation muncul dan sisa berubah. Pembuat request tidak boleh
   memperoleh tombol approve untuk request miliknya sendiri.
7. Buat request lain lalu Reject; alasan penolakan wajib dan sisa tidak berubah.
8. Pada setoran lebih, uji `Kembalikan kepada pemilik dana` dengan referensi
   wajib, lalu uji request `Akui sebagai pendapatan lain` melalui maker-checker.
9. Login sebagai Accounting dan pastikan halaman dapat dibaca tetapi tombol
   mutation/review tidak tersedia.
10. Buka tiap modal lalu tekan `Escape`; modal paling atas harus tertutup tanpa
    mutation. Link bukti harus terbuka di tab baru.

## Compatibility dan Exit

- Cash Deposit Phase 43/44 tetap menjadi satu-satunya source exception.
- history allocation/audit append-only dan direct browser write tetap tertutup.
- Phase 47 boleh ditandai `COMPLETE` setelah smoke Finance, reviewer berbeda,
  Accounting read-only, retry, dan Escape di atas dikonfirmasi user.


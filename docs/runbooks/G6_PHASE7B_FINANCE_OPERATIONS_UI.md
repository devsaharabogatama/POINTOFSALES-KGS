# G6 Corrective Phase 7B — Finance Operations Backoffice

## Status

`UX FORWARD FIX LOCAL READY; DATABASE ROLLOUT + AUTHENTICATED SMOKE PENDING`

Phase 7A migration, postflight, dan behavioral test telah dikonfirmasi PASS oleh
user. Workspace awal Phase 7B sudah dapat dibuka. UX forward fix Phase 7B
menambah nomor manusia server-owned dan menyusun ulang Buku Besar/Journal
Entries; posting contract tetap tidak diperluas.

## Scope yang dibuka

- jurnal canonical POSTED beserta baris dan snapshot akun;
- append-only reversal untuk jurnal `MANUAL` dan `OPENING_BALANCE`;
- pembuatan, penguncian, dan pembukaan kembali accounting period;
- preview, approval, dan process posting queue terkontrol;
- Neraca Saldo, Buku Besar account-centric, Journal Entries document-centric,
  Laba Rugi, Neraca, Pending Analysis, dan Ringkasan
  Rekonsiliasi.
- export Excel `.xlsx` bulanan untuk Buku Besar dan Journal Entries, lengkap
  dengan metadata Company, timezone, periode, waktu generate, dan versi report.

Semua mutation berjalan melalui authenticated API dan guarded RPC. Browser tidak
menulis tabel Finance secara langsung. UUID tidak ditampilkan sebagai identitas
utama pada UI.

## Boundary yang tetap tertutup

- queue hanya menerima contract `STOCK_OPENING` yang sudah didukung;
- 25 historical HOLD dari sembilan contract lain tidak diproses;
- jurnal `AUTOMATIC`, `PRIOR_PERIOD_ADJUSTMENT`, dan `REVERSAL` tidak dapat
  dibalik dari GL; koreksi harus berasal dari workflow dokumen sumber;
- reconciliation bersifat current-state, read-only, dan tidak membuat
  adjustment otomatis;
- UI ini bukan persetujuan maker-checker baru dan tidak mengubah role RPC.

## Evidence lokal

Jalankan dari folder `backoffice`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Expected: lint tanpa error/warning dan production build selesai.

Jika UI pernah menampilkan respons HTML/`Unexpected token '<'`, hentikan proses
Backoffice lama lalu start kembali. Route baru harus mengembalikan JSON; smoke
tanpa token yang benar adalah HTTP `401` dengan
`{"error":"AUTHENTICATION_REQUIRED"}`, bukan halaman HTML.

## Authenticated smoke wajib

Gunakan pilot Company yang mempunyai minimal satu Finance operator serta satu
Company Owner/Admin approver.

1. Ikuti rollout database pada
   `G6_PHASE7B_FINANCE_HUMAN_IDS_LEDGER_EXPORT.md`, restart Backoffice, lalu
   masuk sebagai Finance/Accounting dan buka **Finance > Operasi Finance**.
2. Pastikan Ringkasan, Buku Besar, Journal Entries, Periode, Queue, dan Laporan
   dapat dimuat tanpa UUID/random identifier.
3. Ganti active Company dan pastikan jurnal, periode, queue, exception, akun,
   serta laporan berubah sesuai tenant dan tidak bocor antar Company.
4. Buku Besar harus langsung menampilkan seluruh akun. Expand satu akun,
   periksa saldo awal/debit/kredit/saldo akhir, lalu klik nomor `JUR/...` untuk
   membuka dokumen yang sama pada Journal Entries.
5. Buka jurnal otomatis: tombol pembalikan harus tidak tersedia. Buka jurnal
   `MANUAL`/`OPENING_BALANCE` yang eligible: Finance/Owner/Admin dapat membuka
   modal pembalikan, tetapi submit memerlukan tanggal, alasan, dan konfirmasi.
6. Accounting/Finance dapat membuat period. Finance/Owner/Admin dapat lock.
   Hanya Owner/Admin yang melihat reopen; reopen memerlukan alasan.
7. Buat preview queue. Scope pada kartu dan detail harus tetap **Stok Awal**.
   Tidak adanya event supported harus menghasilkan pesan yang jelas dan tidak
   mengubah HOLD lain.
8. Approve lalu process satu queue yang sudah direview. Muat ulang dan pastikan
   status/count/jurnal konsisten; ulang submit tidak boleh menggandakan efek.
9. Jalankan laporan. Pending Analysis harus menyatakan transaksi pending
   belum masuk laporan keuangan. Reconciliation tidak boleh menawarkan tombol
   adjustment.
10. Export Buku Besar dan Journal Entries untuk satu bulan. File harus dapat
    dibuka sebagai Excel, mempunyai sheet summary/detail/metadata, dan hanya
    memuat Company aktif.
11. Tekan `Esc` pada setiap modal; modal harus tertutup tanpa mutation.

## Compatibility dan next gate

Tampilan jurnal legacy di halaman utama telah dihapus agar tidak bercampur
dengan canonical `finance_journals`. Master Finance, Supplier Invoice/Payment,
Inventory, POS, dan PWA tidak diubah. Setelah smoke lintas-role/lintas-Company
lulus, jalankan pilot reconciliation/stress Phase 7 sebelum membuka Vercel
Preview. HOLD contract lain dan selisih FIFO–GL tetap deferred.

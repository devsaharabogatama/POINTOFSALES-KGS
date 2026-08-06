# G4 Phase 24 — Offline Disconnect/Reconnect Stress

**Status:** READY FOR MANUAL PREFLIGHT

Gate ini menguji recovery jaringan pada kontrak Offline yang sudah dibuka.
Tidak ada migration, perubahan grant, atau modul bisnis baru.

## 1. Preflight

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g4_phase24_offline_disconnect_stress_preflight.sql`

Expected:

- tidak ada `BLOCKER`;
- `disconnect_stress_fixture_readiness=PASS`;
- submission nonterminal berjumlah nol sebelum stress dimulai;
- Stock–Movement, Stock–FIFO, dan allowance consumption seluruhnya cocok.

Jika fixture berstatus `SETUP`, siapkan satu open Cashier Session pada Terminal
Offline aktif, Cash aktif, snapshot terbaru, dan allowance Product yang cukup.
Jangan membuat submission baru sebelum baseline bersih.

## 2. Batas Waktu Client

Build PWA Phase 24 menampilkan tahap aktual dan membatasi request:

- status: 10 detik;
- submit: 15 detik;
- process: 25 detik;
- hasil ambigu memakai `Periksa status` sebelum retry;
- acknowledgement `POSTED` membebaskan UI tanpa menunggu refresh katalog.

Timeout tidak membuktikan transaksi gagal. Jangan membuat Cart atau
`client_transaction_id` baru untuk transaksi fisik yang sama.

## 3. Matrix Disconnect Disposable

Gunakan quantity kecil dan catat kode `OFF-...` setiap transaksi.

1. **Sebelum submit:** matikan jaringan sebelum menekan `Sinkronkan`. Record
   harus tetap lokal dan tidak membuat submission server.
2. **Saat submit:** nyalakan jaringan, tekan `Sinkronkan`, lalu putuskan ketika
   pesan `Mengirim transaksi Offline ke server` tampil. Setelah reconnect,
   tekan `Periksa status`; hasil boleh belum ditemukan atau `QUEUED`, tetapi
   retry tetap memakai identitas yang sama.
3. **Saat process:** putuskan ketika pesan `Membuat invoice dan memperbarui
   stok` tampil. Setelah reconnect, tekan `Periksa status` sampai terminal.
   Jangan menekan sinkronisasi berulang selama status `SYNCING`.
4. **Saat status:** putuskan ketika `Memastikan transaksi tidak diproses dua
   kali` atau pemeriksaan status tampil. UI harus bebas kembali setelah batas
   waktu dan retained record tidak hilang.
5. **Sesudah POSTED:** putuskan segera setelah invoice final dilaporkan tetapi
   sebelum refresh snapshot selesai. Invoice tetap final; setelah reconnect,
   snapshot dapat diperbarui tanpa mengirim Sale ulang.

Untuk satu record yang outcome-nya pernah ambigu, lakukan total sepuluh aksi
`Periksa status`/retry terkontrol dengan key yang sama. Expected tetap satu
submission, satu Sale, satu Payment set, satu Stock Movement effect, dan satu
allowance consumption.

## 4. Closing Evidence

Setelah seluruh record terminal, jalankan:

1. `supabase/diagnostics/g4_phase24_offline_disconnect_stress_preflight.sql`;
2. `supabase/diagnostics/g4_phase23_offline_cold_start_conflict_preflight.sql`;
3. `supabase/diagnostics/g4_phase12_offline_sync_postflight.sql`.

Expected tidak ada submission `QUEUED`, `SYNCING`, `NEEDS_CONFIRMATION`, atau
`FAILED`; seluruh final-effect dan stock reconciliation tetap bersih.

Kirim hasil preflight awal terlebih dahulu. Setelah stress, kirim hasil tiga
diagnostic, kode record uji, stage pemutusan, durasi sampai UI bebas, dan status
akhir. Jangan kirim password, token, payload, atau data Customer.

## 5. Boundary dan Next Safe Step

- Offline Return, Customer Balance, TEMPO, Expense, Deposit, dan Purchasing
  tetap tertutup;
- jangan menghapus queue/acknowledgement untuk membersihkan fixture;
- jangan mengedit Sale/Payment/Stock final langsung;
- cleanup hanya release allowance tersisa dan close Session setelah seluruh
  queue terminal.

Setelah matrix disconnect/reconnect dan closing reconciliation lulus, tutup
G4 Offline core dan lanjutkan roadmap G4 ke requirement operasional berikutnya.

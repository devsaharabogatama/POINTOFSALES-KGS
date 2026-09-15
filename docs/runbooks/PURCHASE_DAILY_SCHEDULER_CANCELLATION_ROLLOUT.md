# Purchase Daily Replenishment Step 6/6B — Scheduler dan Cancellation

**Status:** base migration DATABASE LIVE; behavioral menemukan defect batas tengah malam; forward-fix LOCAL READY  
**Target tunggal:** Supabase Development `fkywtxucmyjvpwdiqpix`  
**Production/staging:** dilarang untuk paket ini

## Outcome

- `AUTO_RO` dan `AUTO_PO` dijalankan pukul `23:59` berdasarkan timezone Company.
- Actor yang ditampilkan untuk eksekusi terjadwal adalah `Sistem Otomatis`.
- Identitas tanggal tetap terlihat pada nomor dokumen canonical:
  `RO-YYYYMMDD-*`, `POB-YYYYMMDD-*`, dan `PO-YYYYMMDD-*`.
- RO otomatis yang masih `DRAFT` dapat dibatalkan.
- PO yang belum mempunyai Receipt `POSTED` dapat dibatalkan; Receipt Draft ikut
  ditutup sebagai `CANCELED`.
- PO dengan Receipt `POSTED` ditolak saat dibatalkan selama quantity
  stock-bearing yang belum diretur masih lebih dari nol.
- Setelah seluruh quantity `accepted good + damaged` dari Receipt Posted sudah
  mempunyai Purchase Return Posted, PO dapat dibatalkan. Receipt dan Return
  Posted tetap immutable dan tidak dihapus.

## Impact map

### Direct

- Menambah summary run scheduler, attempt history append-only, dan operation
  idempotency cancellation.
- Menambah RPC cancellation RO/PO serta helper net received setelah Return.
- Memperluas status transition guard Supplier Order dan daily batch secara
  sempit untuk `... -> CANCELED` setelah invariant Return terpenuhi.
- Mendaftarkan satu job `pg_cron` yang berjalan tiap menit; function hanya
  mengeksekusi Company yang waktu lokalnya berada pada menit `23:59`.

### Downstream yang dipertahankan

- Stock, FIFO, movement, AP, Financial Event, dan Journal tidak dibalik oleh
  cancellation. Seluruh efek barang yang sudah diterima tetap dibalik hanya
  melalui Purchase Return canonical.
- `MANUAL` tetap mode default dan tidak diproses scheduler.
- POS, Sales Retail/Office, Reservation, Cashier Session, dan Payment tidak
  diubah oleh migration ini.
- RPC Purchase lama tidak dihapus; client Step 6/6C akan diarahkan ke RPC baru.

### Concurrency dan retry

- Generator lama tetap menjadi authority untuk lock Company/date dan duplicate
  daily batch.
- Scheduler memakai operation UUID deterministik per Company/date/mode.
- Cancellation memakai advisory transaction lock, optimistic `master_version`,
  request hash, dan exact retry snapshot.

## Urutan forward-fix saat ini

Base migration `20260914140000` sudah terpasang dan tidak boleh dijalankan atau
diubah ulang. Behavioral membuktikan scheduler tidak memilih Company pada
`23:59:30`: upper bound bertipe `time` berubah dari `23:59 + 1 minute` menjadi
`00:00`, sehingga perbandingan `23:59:30 < 00:00` selalu salah.

Jalankan file berikut secara penuh dan berurutan:

1. [Forward-fix preflight](../../supabase/diagnostics/purchase_daily_scheduler_midnight_window_fix_preflight.sql)
2. [Forward-fix migration](../../supabase/migrations/20260914141000_purchase_daily_scheduler_midnight_window_fix.sql)
3. [Behavioral test](../../supabase/tests/purchase_daily_scheduler_cancellation_behavior.sql)
4. [Forward-fix postflight](../../supabase/diagnostics/purchase_daily_scheduler_midnight_window_fix_postflight.sql)
5. [Main postflight](../../supabase/diagnostics/purchase_daily_scheduler_cancellation_postflight.sql)

Forward-fix hanya mengganti seleksi window menjadi timestamp lokal lengkap
`[tanggal 23:59:00, tanggal berikutnya 00:00:00)`. Nama cron job, generator,
operation UUID, run/attempt history, dan cancellation tidak diubah.

## Urutan instalasi awal (referensi)

Jalankan setiap file secara penuh, satu per satu, pada SQL Editor project
`fkywtxucmyjvpwdiqpix`. Hentikan bila ada SQL error, `BLOCKER`, atau `FAIL`.

1. [Preflight](../../supabase/diagnostics/purchase_daily_scheduler_cancellation_preflight.sql)
2. [Migration](../../supabase/migrations/20260914140000_purchase_daily_scheduler_cancellation_runtime.sql)
3. [Behavioral test](../../supabase/tests/purchase_daily_scheduler_cancellation_behavior.sql)
4. [Postflight](../../supabase/diagnostics/purchase_daily_scheduler_cancellation_postflight.sql)

Behavioral test dibungkus `BEGIN/ROLLBACK` dan membuat Company/master/Receipt/
Return sendiri. Bukti yang wajib muncul adalah notice `TEST_PASS` yang mencakup:

- scheduler system identity dan exact retry;
- RO Draft cancellation dan retry;
- PO tanpa Receipt Posted dapat dibatalkan;
- PO setelah Receipt Posted ditolak;
- full Purchase Return Posted menurunkan net received ke nol;
- PO kemudian dapat dibatalkan tanpa menghapus Receipt/Return Posted.

## Manual smoke setelah seluruh SQL PASS

Belum boleh disebut `SMOKE PASS` sebelum client Step 6/6C tersedia. Setelah UI
tersedia, lakukan minimal:

1. pilih Company mode `AUTO_RO`, pastikan RO hasil scheduler menampilkan
   `Sistem Otomatis` dan tanggal pada nomor;
2. cancel satu RO Draft;
3. pada Company `AUTO_PO`, cancel satu PO sebelum Receive;
4. post satu Receipt lalu pastikan cancel PO ditolak;
5. post Return penuh, lalu cancel PO dan pastikan histori Receipt/Return tetap ada;
6. ulangi request cancel yang sama dan pastikan tidak ada audit/efek ganda;
7. verifikasi Company lain dan mode `MANUAL` tidak memperoleh dokumen otomatis.

## Rollback / forward-fix

- Jika migration gagal sebelum `COMMIT`, seluruh DDL dan registrasi cron rollback.
- Setelah migration committed, jangan edit file migration ini.
- Emergency stop scheduler dilakukan dengan menonaktifkan job
  `kgs-purchase-daily-replenishment`; jangan drop histori run/cancel.
- Defect setelah apply diperbaiki dengan migration forward-fix additive.
- PO/Receipt/Return yang sudah posted tidak boleh dipulihkan melalui direct
  update atau delete.

## Status gate

- Local file/static verification: base dan forward-fix tersedia; final SQL
  runtime gate dijalankan user.
- Database Development: base migration live; forward-fix/behavior/postflight
  pending user execution.
- Client deployed: belum.
- Authenticated smoke: belum.
- UAT: belum.

# G4 Phase 23 — Offline Cold-Start and Conflict Recovery Preflight

**Status:** READY FOR MANUAL PREFLIGHT

Gate ini hanya mengaudit kesiapan pemulihan transaksi Offline setelah aplikasi
ditutup atau dimulai tanpa jaringan. Gate ini belum mengubah schema, data,
entitlement, Terminal policy, ataupun perilaku PWA.

## Tujuan

Phase 22 sudah mendukung Offline checkout selama Session, scope operasional, dan
snapshot masih tersedia di aplikasi yang sedang berjalan. Phase 23 memisahkan
kontrak berikut sebelum cold-start dibuka:

- identitas transaksi dan payload tetap immutable serta idempotent;
- retry server mengunci submission dan tidak menggandakan final effect;
- status submission dapat dipulihkan sebelum client mencoba submit ulang;
- submission gagal atau perlu konfirmasi tidak memiliki Sale/allowance final;
- submission `POSTED` memiliki acknowledgement dan Sale final yang lengkap;
- Stock, Movement, dan FIFO tetap berekonsiliasi;
- PWA nantinya memulihkan scope, identitas auth, katalog, queue, dan status
  secara fail-closed.

## Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g4_phase23_offline_cold_start_conflict_preflight.sql`

Query bersifat `SELECT`-only dan hanya mengembalikan aggregate count.

## Hasil yang Diharapkan

- seluruh status kontrak server dan rekonsiliasi: `PASS`;
- `offline_recovery_runtime_inventory`: `INFO`;
- `offline_recovery_uat_scope`: `PASS` bila entitlement, Terminal policy, dan
  open Session siap; `SETUP` masih valid bila scope UAT belum disiapkan;
- `pwa_cold_start_retained_contract`: `SETUP` karena implementasi client baru
  boleh dibuka setelah preflight ini bersih;
- tidak ada `BLOCKER`;
- `stale_syncing_offline_submission` harus `PASS`.

## Boundary

- jangan menghapus retained record setelah retry atau acknowledgement;
- jangan menebak hasil transaksi hanya dari cache lokal;
- pada reconnect, periksa status server lebih dulu sebelum submit ulang;
- `NEEDS_CONFIRMATION` harus tampil sebagai keputusan terkontrol, bukan retry
  otomatis tanpa batas;
- allowance tetap reservasi stock eksplisit dan tidak dibuat otomatis;
- Customer Balance, Purchase, Return, dan modul deferred lain tidak dibuka oleh
  gate ini.

## Next Safe Step

Jika tidak ada `BLOCKER`, implementasikan bootstrap PWA yang memulihkan exact
operational scope, mencocokkan cached auth identity, membuka snapshot yang
masih valid, memuat retained queue, lalu menjalankan status-first reconnect.
Setelah itu lakukan cold-start dan conflict/retry stress pada scope disposable.

# G6 Corrective Phase 7 - Finance Operations and Pilot Preflight

## Outcome

Membuktikan live database aman sebelum Backoffice membuka operasi Finance
canonical: controlled posting queue, period lock/reopen, append-only reversal,
posted reports, pending analysis, reconciliation review, dan pilot terbatas.

Preflight ini tidak membuat atau memproses queue, tidak mem-posting/reversal
journal, tidak mengubah period, dan tidak membuat reconciliation document.

## Jalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g6_phase7_finance_operations_pilot_preflight.sql`

Kirim seluruh hasil `check_name,status,details` sebelum migration atau UI Phase
7 dibuat.

## Interpretasi

- `BLOCKER`: berhenti dan perbaiki live-state/authority terlebih dahulu.
- `REVIEW`: review queue failure sebelum rollout.
- `BACKFILL`: konfigurasi pilot belum lengkap, bukan izin memilih data secara
  otomatis.
- `SETUP`: capability append-only reversal memang belum dibuka dan menjadi
  scope rollout berikutnya.
- `DEFERRED`: 25 event HOLD dan selisih FIFO-GL tetap di luar Phase 7 awal.
- `PASS`: invariant telah siap.

Expected gap pertama adalah `canonical_finance_reversal_runtime=SETUP`. Jangan
mengganti gap ini dengan edit/delete jurnal posted atau direct table write.

## Boundary pilot

- satu Company, satu Store, satu Terminal;
- Finance operator dan Company Owner/Admin approver tersedia;
- browser hanya memakai guarded RPC/API;
- queue memproses hanya contract yang sudah didukung;
- reversal selalu membuat journal baru dan tidak membuka history lama;
- period reopen membutuhkan alasan dan authority Company Owner/Admin;
- P&L/Neraca tetap POSTED-only;
- pending analysis tetap berlabel `BELUM MASUK LAPORAN KEUANGAN`;
- tidak ada auto-adjustment untuk selisih reconciliation.

## Rollback

Tidak diperlukan. File preflight bersifat SELECT-only. Bila query gagal karena
schema drift, hentikan dan perbaiki diagnostic berdasarkan live catalog; jangan
menjalankan DDL spekulatif.

# Laporan Pengembangan Lokal Backoffice AR Finance

Tanggal: 2026-11-10

## Ringkasan

Alur AR berbasis open item kini tersedia lokal: Invoice, Receipt, Credit Note,
allocation, refund, Customer Balance opsional, reversal, dan Invoice pengganti
dapat ditelusuri tanpa menulis ulang Journal historis. Semua database work pada
laporan ini dijalankan di Docker lokal. Production tidak diubah.

| Task | Hasil lokal | Evidence |
|---|---|---|
| 1. Audit/desain | Flow SO hingga AR settlement dipetakan | audit/handoff |
| 2. Foundation | Registry, allocation, operation, audit, read RPC | postflight; cumulative Task 3 |
| 3. Invoice/Receipt | Partial/full allocation dan residual Receipt credit | behavior PASS |
| 4. Credit Note | Native Credit Note menjadi unallocated open credit | Task 4 runtime; Task 5/6 behavior |
| 5. Credit actions | Allocate, refund, balance convert/use, reversal | behavior/postflight PASS |
| 6. Replacement | Atomic post/allocation dan editable replacement Draft | behavior/postflight PASS |
| 7. Client/API | Dua aksi Credit Note, replacement detail/lineage | 55/55 tests, lint/typecheck/build PASS |
| 8. Backlog | SELECT-only local inventory, tanpa reclassification | dummy local selesai; Production pending |
| 9. Closure | E2E checklist, rollout, status/report | dokumen ini dan runbook |
| Date fix | Receipt memakai tanggal Company, bukan UTC | pre/postflight + Task 3 PASS |

## Masalah yang ditemukan

- Task 6 boundary awal mencakup fixture: `TEST_HARNESS_FIX`; assertion produk
  tidak dilemahkan.
- Task 3 menemukan guard Receipt memakai UTC dan menolak tanggal sah timezone
  Company: `PRODUCT FIX` via forward migration `20261110110000`.
- Task 8 sempat memakai identifier tidak ada: berhenti tanpa mutation, lalu
  diperbaiki dari defining runtime.
- RETAINED_RETAIL tidak memiliki sumber historis eligible lokal. Runtime
  contract terbukti, behavior tetap `BELUM TERBUKTI`; tidak dibuat pseudo-PASS.

## Evidence lokal

- Task 3 cumulative behavior: PASS dan rollback.
- Task 5 behavior: PASS dan rollback.
- Task 6 behavior: PASS dan rollback.
- Task 2â€“6 postflight mandatory rows: PASS.
- Receipt Company-date pre/postflight: PASS.
- Backoffice tests 55/55; lint 0 error; TypeScript dan build PASS.
- Legacy inventory lokal: nol candidate pada dummy data; bukan bukti Production.
- Docker database container healthy; proven private migration ledger contains
  exactly six expected versions: Task 2-6 and the Receipt date fix.

## Compatibility

POS/RETAINED_RETAIL tidak diarahkan ke flow baru; Stock/Reservation/FIFO/HPP
dan dispatch tidak berubah oleh aksi AR; Receipt/DP tidak disalin; plain Credit
Note tetap ada; Customer Balance tetap opt-in dan hanya sesudah Invoice Posted;
historical Posted Journal tetap immutable; Company pajak tetap fail-closed.

## Status

- `AUDIT COMPLETE`: YES
- `LOCAL READY`: YES untuk automated gates di atas
- `DATABASE LIVE`: LOCAL DOCKER ONLY
- `CLIENT DEPLOYED`: NO
- `AUTHENTICATED BROWSER SMOKE`: NO
- `UAT PASS`: NO
- `PRODUCTION CHANGED`: NO

## Sisa gate

User menjalankan browser smoke/UAT lokal; RETAINED_RETAIL dibuktikan pada
environment dengan fixture eligible; Production legacy inventory direview;
baru kemudian database rollout, client deploy, smoke, dan UAT Production boleh
dipertimbangkan dengan instruksi terpisah.

## Addendum - reversal consumer parity

Browser UAT menemukan Invoice pengganti hilang dari AR Aging setelah operasi
`APPLY CREDIT` dibalik. Root cause terbukti pada helper Task 4 yang menjumlahkan
baris allocation dan reversal sebagai positif. Local forward migration
`20261110130000` memperbaiki helper bersama tanpa mengubah Journal atau data
historis.

Evidence penutupan lokal:

- preflight: satu mismatch nyata, dependency/anchor/boundary PASS;
- postflight: ledger/runtime/data parity PASS;
- rollback behavior Task 3, Task 4, Task 5, Credit Note outstanding, dan Task 6
  replacement PASS;
- authenticated Chrome/API: AR Aging dan open-item sama-sama Rp50.000;
  Invoice pengganti `INV-20261110-0000000023` kembali terlihat Rp30.000;
- retained-Retail full refund bridge: `FIXTURE BLOCKED`, bukan PASS.

Status terbaru: `LOCAL READY` dan `AUTHENTICATED BROWSER SMOKE PASS` untuk
Backoffice native flow yang diuji; `UAT PASS` keseluruhan masih NO karena gap
retained-Retail dan Customer Balance aktif tidak tersedia pada konfigurasi
lokal; Production tetap tidak berubah.

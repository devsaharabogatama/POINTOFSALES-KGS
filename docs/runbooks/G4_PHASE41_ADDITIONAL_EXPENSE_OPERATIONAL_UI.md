# G4 Phase 41 — Additional Expense Operational UI

Status: `READY FOR AUTHENTICATED ROLE SMOKE`

Phase 40 migration, postflight, corrected behavioral test, seluruh regression,
dan closing postflight telah dikonfirmasi user berhasil. Phase ini tidak
menambah schema: UI hanya membuka RPC guarded Phase 40.

## Boundary

- Backoffice `Finance > Approval Expense`:
  - menampilkan riwayat request dana tambahan per dokumen;
  - approve/reject request `SUBMITTED`;
  - membayar request `APPROVED` non-Cash dengan nominal/metode read-only.
- POS `Expense > Penyelesaian`:
  - menampilkan request tambahan Cash yang sudah `APPROVED` pada Store aktif;
  - mencairkan tepat nominal approved melalui Cashier Session aktif;
  - memperbarui expected cash dari hasil server.
- Approval tetap cash-neutral. Cash hanya POS; non-Cash hanya Backoffice.
- Semua mutation tetap tenant-scoped, versioned, idempotent, audited, dan
  server-authoritative.

Offline Expense, Deposit, correction/reversal, jurnal final G6, dan Purchasing
G5 tidak dibuka.

## Smoke test manual

Gunakan Expense `DISBURSED`/`PARTIALLY_SETTLED` dengan outstanding positif.

1. POS — `Expense > Penyelesaian`, ajukan tambahan Cash.
2. Backoffice — buka dokumen, pastikan request `SUBMITTED`, nominal, metode,
   pembuat, waktu, dan bukti tampil; approve tanpa alasan.
3. Pastikan approval tidak mengubah expected cash atau membuat disbursement.
4. POS — muat ulang `Penyelesaian`; request tampil pada `Dana tambahan siap
   dicairkan`. Cairkan dan pastikan expected cash turun tepat nominal approved.
5. Muat ulang kedua aplikasi; request harus `DISBURSED`, tidak boleh dicairkan
   ulang, dan total dokumen/outstanding bertambah tepat sekali.
6. Buat request tambahan non-Cash; approve lalu `Bayar dana tambahan` dari
   Backoffice. Pastikan kas laci tidak berubah.
7. Buat request disposable lain dan reject dengan alasan. Pastikan tidak ada
   cash/disbursement effect.
8. Uji role tanpa approval/non-Cash authority: tombol tidak tersedia dan RPC
   server tetap menolak bila dipanggil langsung.
9. Pastikan Escape menutup setiap dialog yang tidak sedang menyimpan.

Sesudah smoke, jalankan kembali closing postflight Phase 40 untuk memastikan
single disbursement, event, drawer, document total, audit, dan reconciliation
tetap `PASS`.

## Evidence lokal

- `pwa`: `npm.cmd run lint` PASS; `npm.cmd run build` PASS.
- `backoffice`: `npm.cmd run lint` PASS; `npm.cmd run build` PASS.
- Next production build menemukan route:
  - `/api/finance/expense-additional-requests/[id]/review`;
  - `/api/finance/expense-additional-requests/[id]/disburse`.

## Next safe step

Tunggu authenticated role/effect smoke user. Jangan membuka Deposit, Offline
Expense, correction/reversal, atau jurnal G6 dari Phase 41.

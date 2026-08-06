# G4 Phase 35 — Expense Disbursement Operational UI

**Status:** LOCAL READY — authenticated smoke required  
**Requirement:** POS-007, POS-009  
**Dependency:** migration `20260803070000` dan seluruh Phase-34
postflight/behavior/regression sudah dikonfirmasi PASS oleh user.

## Outcome

- satu menu `Expense` di PWA memiliki tab `Ajukan` dan `Cairkan Tunai`;
- Kasir hanya melihat Expense `APPROVED + CASH` yang dapat dibaca pada Store
  sesi aktif;
- nominal, metode, Store, dan status berasal dari dokumen approved dan tidak
  dapat diubah dari UI;
- pencairan Cash memakai `disburse_expense(...)`, Session aktif, stable
  idempotency key, optional/required HTTPS evidence, dan menampilkan
  `expectedCashAfter` dari server;
- Backoffice `Finance > Approval Expense` menampilkan pembayaran non-Cash
  untuk Company Owner/Admin/Finance melalui route authenticated dan RPC yang
  sama;
- Expense Cash di Backoffice hanya memberi arahan `Cairkan dari POS / sesi
  kasir`; route Backoffice menolak Cash;
- Accounting tetap read-only dan Store Manager tidak dapat mengonfirmasi
  Transfer/non-Cash.

## Boundary

Fase ini hanya membuka **initial disbursement** sebesar nilai approved.
Settlement biaya aktual, return/pengembalian, additional disbursement, Cash In,
Offline Expense, Deposit, Customer Balance settlement, serta jurnal final G6
tetap tertutup. Financial Event hasil pencairan tetap `HOLD`.

## Automated Evidence

Jalankan dari root workspace:

```powershell
cd pwa
npm.cmd run lint
npm.cmd run build

cd ..\backoffice
npm.cmd run lint
npm.cmd run build
```

Expected:

- PWA lint PASS dan Vite/PWA production build PASS;
- Backoffice ESLint PASS dan Next production build PASS;
- route `/api/finance/expenses/[id]/disburse` terdeteksi sebagai dynamic route.

## Authenticated Smoke

Gunakan dua Expense approved disposable yang sudah tersedia: satu Cash dan satu
non-Cash. Jangan memakai direct table write.

### A. Cash melalui PWA

1. Restart/hard refresh PWA, login, lalu buka Cashier Session yang benar.
2. Buka `Expense > Cairkan Tunai`.
3. Pastikan hanya dokumen Cash approved Store tersebut yang muncul; nominal dan
   metode tidak dapat diedit.
4. Pilih dokumen. Isi link HTTPS bila metode mewajibkan bukti.
5. Centang konfirmasi hanya setelah uang siap diserahkan, lalu pilih
   `Cairkan Tunai`.
6. Expected: status menjadi `DISBURSED`, notice memuat nominal, dan expected
   cash sesi turun tepat satu kali.
7. Buka ulang tab. Dokumen yang sudah dicairkan tidak muncul lagi.
8. Bila kas sesi kurang, expected error adalah `Kas sesi tidak cukup`; tidak
   boleh ada disbursement, drawer movement, atau event parsial.

### B. Non-Cash melalui Backoffice

1. Login sebagai Finance/Company Owner/Company Admin dan buka
   `Finance > Approval Expense`.
2. Filter `Disetujui`, buka dokumen Transfer/non-Cash.
3. Pastikan tombol `Konfirmasi Pembayaran` muncul dan nominal/metode read-only.
4. Isi link HTTPS bila diwajibkan, centang konfirmasi bahwa pembayaran benar
   sudah dieksekusi, lalu submit.
5. Expected: status `DISBURSED`, amount/outstanding sama dengan nilai approved,
   tidak ada Cash Drawer Movement, dan event Finance tetap `HOLD`.
6. Buka Expense Cash dari Backoffice. Expected: tidak ada tombol pembayaran;
   UI mengarahkan pencairan ke POS.
7. Login Accounting/Store Manager. Expected: tidak ada tombol konfirmasi
   non-Cash; request manual tetap ditolak RPC.

### C. Database closing check

Setelah kedua smoke selesai, jalankan:

1. `supabase/diagnostics/g4_phase34_expense_disbursement_postflight.sql`;
2. verifikasi seluruh check `PASS`/`INFO`;
3. pastikan tepat satu disbursement dan satu Finance Event per dokumen;
4. Cash mempunyai satu drawer `OUT`; non-Cash tidak mempunyai drawer row;
5. rerun exact UI action tidak menggandakan efek.

## Compatibility dan Recovery

- request/approval Phase-31/32 tetap memakai execution path yang sama;
- migration Phase-34 tidak dijalankan ulang dan tidak diedit;
- jika UI gagal setelah RPC sukses, muat ulang daftar terlebih dahulu—jangan
  membuat direct insert/update;
- bila smoke gagal, hentikan pada dokumen tersebut dan kirim notifikasi/error
  persis beserta hasil closing postflight.

## Next Safe Step

Setelah Cash dan non-Cash authenticated smoke serta closing postflight PASS,
lanjutkan roadmap Expense ke SELECT-only preflight settlement/actual/return.
Jangan membuka Cash In atau jurnal G6 dari fase UI ini.

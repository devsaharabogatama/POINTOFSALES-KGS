# G4 Phase 31 — Expense Request PWA UI

## Outcome

Membuka pengajuan Expense online dari PWA untuk Cashier dengan Session aktif.
UI memakai kategori dan Payment Method aktif pada Company/Store, lalu memanggil
`save_expense_draft` dan `submit_expense_request`. Fase ini tidak mencairkan
Cash/Transfer dan tidak mengubah drawer, stock, atau jurnal.

## Preconditions

- migration `20260803040000` sudah applied;
- postflight, behavioral test, dan regression Phase 30 seluruhnya PASS;
- Super Admin mengaktifkan feature `Expense Operasional` untuk Company uji;
- Company memiliki kategori Expense aktif dan Payment Method eligible;
- Cashier sudah login, memilih Terminal/Gudang, dan membuka Session.

## Authenticated Tablet Smoke

1. Restart PWA atau hard refresh agar bundle terbaru dimuat.
2. Dengan feature off, pastikan tombol `Expense` tidak tampil.
3. Aktifkan feature dari Backoffice, refresh katalog PWA, lalu pastikan tombol
   `Expense` tampil.
4. Buka modal dan cek:

   - label memakai nama kategori dan nama metode, bukan UUID/kode internal;
   - `Escape`, tombol tutup, dan backdrop menutup modal;
   - default metode kategori dipilih bila eligible;
   - kategori dengan evidence `REQUIRED` menolak link kosong/non-HTTPS;
   - penanggung jawab dapat memakai user aktif atau pihak luar bernama.

5. Ajukan satu Expense Cash. Expected result:

   - nomor `EXP-...` ditampilkan;
   - status `SUBMITTED` bila approval required, atau `APPROVED` bila auto;
   - pesan menegaskan dana belum dicairkan.

6. Ajukan satu Expense Transfer/non-tunai dan verifikasi hasil yang sama.
7. Pastikan request/approval tidak mengubah:

   - `cashier_sessions.expected_cash`;
   - stock/FIFO/Stock Movement;
   - journal final.

8. Matikan jaringan. Tombol Expense harus disabled dan cold-start Offline tidak
   boleh menghidupkan feature Expense dari retained catalog.

## Automated Evidence

Jalankan dari folder `pwa`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Keduanya wajib sukses tanpa mematikan lint/typecheck. Expense modal dibangun
sebagai lazy chunk agar tidak memperbesar jalur awal lebih dari yang diperlukan.

## Failure / Recovery

- Jika Save berhasil tetapi response Submit gagal, jangan ganti isi form atau
  tutup modal; tekan `Ajukan Expense` kembali. `client_expense_id` yang sama
  membuat Save idempotent dan Submit dilanjutkan dari Draft yang sama.
- `EXPENSE_FEATURE_DISABLED`: cek entitlement Company dan refresh PWA.
- `ACTIVE_EXPENSE_CATEGORY_NOT_FOUND`: aktifkan/siapkan kategori lalu refresh.
- `ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND`: cek assignment metode ke Store.
- `OPEN_EXPENSE_SESSION_REQUIRED`: buka kembali Session untuk metode Cash.

## Compatibility dan Boundary

- Tidak ada migration baru pada Phase 31.
- Flow Sale, Return, Offline Sale queue, printer, Customer, dan Pricelist tidak
  diubah.
- Offline catalog mengisi `expenseEnabled=false` dan kategori kosong secara
  eksplisit; Offline Expense belum dibuka.
- Approval hanya mengubah status request. Disbursement, settlement, return,
  Cash In, Deposit, drawer mutation, Finance posting, dan G5 Purchasing tetap
  di luar Phase 31.

## Next Safe Step

Setelah authenticated smoke PASS, lanjutkan boundary roadmap berikutnya:
Backoffice approval Expense atau preflight disbursement. Jangan membuat
pencairan dari UI request tanpa kontrak server, audit, idempotency, dan
reconciliation tersendiri.

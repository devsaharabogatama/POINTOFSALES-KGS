# Revisi SLD — Checkout Delivery dan Ongkir

**Status:** R1-R4 user-verified; PRD-1 opened  
**Tanggal:** 2026-08-12  
**Posisi gate:** sesudah SLD-2 database PASS; menggantikan closing UAT SLD-3 lama sebelum PRD-1

## 1. Keputusan User

1. Form delivery tidak memenuhi cart utama. Checkbox `Perlu dikirim` muncul pada konfirmasi checkout final, sebelum payment dan POST Sale.
2. Saat dicentang, penerima, telepon, dan alamat mengambil default dari Customer terpilih, tetap dapat direview/dikoreksi sebagai snapshot transaksi.
3. Walk-In delivery wajib mengisi identity penerima secara eksplisit.
4. Ongkir opsional, default nol, menjadi bagian grand total, tender/payment, piutang TEMPO, Customer Balance, dan snapshot online/offline.
5. Invoice mempunyai opsi tampilkan rincian ongkir. Menyembunyikan rincian hanya mengubah presentasi; total final dan pencatatan Finance tidak berubah.
6. Ongkir yang ditagihkan ke Customer dicatat terpisah sebagai pendapatan ongkir. Biaya nyata yang dibayar ke kurir adalah Expense terpisah.

Checkbox wajib berada sebelum POST. Sale POSTED tidak boleh diubah nilainya hanya karena operator membuka atau mencetak nota.

## 2. Invariant

- server menghitung ulang `delivery_fee_amount >= 0` dan grand total;
- payment, change, Customer Balance, dan receivable merekonsiliasi total setelah ongkir;
- exact retry menghasilkan Sale, Invoice, Surat Jalan, event, dan jurnal yang sama;
- offline payload menyimpan policy/snapshot ongkir dan server tetap menghitung ulang;
- Invoice dapat `SHOW_SEPARATE` atau `HIDE_BREAKDOWN`; total final selalu tampil dan angka ongkir tidak dipindahkan ke line Product;
- Surat Jalan tidak menampilkan harga/ongkir;
- print/lifecycle tidak mengubah ongkir, Stock, Payment, atau Finance;
- pendapatan ongkir memakai account-function/mapping Company yang eksplisit;
- Return tidak boleh menganggap ongkir sebagai quantity Product. Refund ongkir harus eksplisit dan diaudit.

## 3. Urutan Implementasi

### SLD-R1 — Contract dan preflight

Audit total Sale, snapshot, payment, offline envelope, Return, `SALE_POSTED`, posting expression, COA/function, dan migration SLD-2 live. Kunci kolom/payload, display mode, rounding, idempotency, Tax, dan refund ongkir.

### SLD-R2 — Canonical delivery-fee/Finance foundation

Additive schema, server-side total resolution untuk online/offline/split/TEMPO/Customer Balance, amount event ongkir, jurnal pendapatan ongkir, zero-value legacy backfill, postflight, behavioral, tenant, concurrency, dan reconciliation.

Local implementation 2026-08-11 menutup schema, total, receipt/Invoice/Event,
account function, COA, dan Company fallback mapping. Actual Sale journal tetap
controlled `HOLD` karena G6 atomic posting live baru mendukung Stock Opening;
rule/resolver Sale tidak boleh dibuka diam-diam dari SLD. Manual migration,
postflight, behavior, dan regression R2 masih menunggu user.

### SLD-R3 — Checkout confirmation dan printable UI

Pindahkan selector ke confirmation step sebelum bayar, autofill Customer, validasi Walk-In, field ongkir, toggle Invoice, draft restore, offline queue, success receipt, Invoice/SJ print, dan breakdown internal Backoffice.

**Status 2026-08-11:** local-ready setelah R2 user-verified PASS. Lint/build
PWA dan Backoffice PASS; authenticated online/offline/print smoke masih wajib
menurut `runbooks/SLD_R3_DELIVERY_CHECKOUT_PRINT_UAT.md` sebelum R4 dibuka.

### SLD-R4 — Return, Finance, dan closing regression

Terapkan refund ongkir sesuai keputusan R1 dan uji Sale/payment/AR/Customer Balance/event/journal, online/offline, split, TEMPO, Bundle, retry, two-Company, role, print, dan logo. Setelah PASS baru kembali ke PRD-1.

**Status 2026-08-12:** user mengonfirmasi migration `20260811150000`,
postflight, rollback-safe behavior, dan regression seluruhnya sukses. Partial
Return tidak pernah menawarkan/menerima ongkir; full remaining Return default
OFF dan harus dipilih eksplisit. R4 ditutup dan authenticated role/two-Company
matrix dilanjutkan sebagai closing PRD-1.

## 4. Keputusan Sebelum SLD-R2

1. **Pajak ongkir:** rekomendasi v1 tidak menerapkan pajak secara implisit. Jika kena pajak, Tax Rule wajib eksplisit dan tersnapshot.
2. **Refund ongkir:** rekomendasi v1 tidak otomatis refund pada partial Product Return; full cancellation/Return menyediakan pilihan eksplisit dengan approval/audit.

## 5. Compatibility

- payload lama tanpa fulfillment tetap `PICKUP` dan ongkir nol;
- Invoice/SJ final existing tetap immutable dan tidak dibangun ulang;
- UAT SLD-3 lama ditahan/superseded, bukan dinyatakan gagal;
- dokumen rencana ini belum mengubah schema atau runtime.

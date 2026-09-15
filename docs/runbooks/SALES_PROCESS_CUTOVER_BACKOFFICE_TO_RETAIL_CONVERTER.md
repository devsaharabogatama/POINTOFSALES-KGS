# Sales Process Cutover Backoffice to Retail Converter — Step 4C/6

Status: **DATABASE LIVE; FORWARD-FIX, BEHAVIOR, DAN KEDUA POSTFLIGHT
USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.

Target hanya isolated Supabase Development `fkywtxucmyjvpwdiqpix`.
Production/staging tidak boleh disentuh.

## Mapping yang sudah dikunci

- Draft, Sent, dan Confirmed Backoffice yang masih eligible menjadi Retail
  Draft. Tidak ada target yang langsung menjadi Reserved atau menerbitkan
  Invoice/SJ pada saat cutover.
- Confirmed TEMPO bertanggal masa depan menjadi Retail Scheduled Draft.
  Reservation dan DO Backoffice dilepas/dibatalkan; seluruh target wajib
  dikonfirmasi ulang pada Retail sebelum Reservation, SJ, dan Invoice dibuat.
- Future non-TEMPO dan multi-installment tetap `BLOCKED`/grandfathered.
- Target memakai origin `BACKOFFICE_CUTOVER` tanpa Cashier Session/POS Terminal
  palsu.
- Nilai harga, discount, tax, rounding, ongkir, tanggal, dan satu due date
  dipertahankan dari source. Resolver Retail baru berlaku setelah target diedit.
- Backoffice dan Retail tidak mempunyai titik penerbitan Invoice yang sama:
  Backoffice memakai Qty customer receipt, sedangkan Retail lama memakai rantai
  konfirmasi Order. Converter hanya membuat Draft tanpa Invoice; setelah target
  dikonfirmasi ulang, lifecycle berikutnya mengikuti kebijakan Retail.

## Impact map

- Direct pada migration berikutnya: open Quotation/SO Backoffice, line,
  Reservation/DO yang belum dikirim, target Retail header/line/requirement,
  serta audit dan exact-operation lineage.
- Downstream yang wajib tetap nol saat conversion: Stock Movement, On Hand,
  FIFO/COGS, payment, Cashier Session/Drawer, procurement/PO, Finance event,
  queue, dan journal.
- Public Apply, perubahan Company mode, dan UI tetap tertutup pada Step 4C.
- Kegagalan satu bagian wajib merollback target, retirement source, dan seluruh
  Reservation/DO transfer dalam transaksi yang sama.

## Evidence rollout Development

1. Pastikan SQL Editor menunjuk project Development
   `fkywtxucmyjvpwdiqpix`.
2. Preflight telah USER-PASS: dua row `SETUP` expected dan seluruh `BLOCKER`
   nol. Satu confirmed source dengan fulfillment tidak canonical akan
   diklasifikasikan `FULFILLMENT_SHAPE_MUST_REPAIR`, bukan dipaksa konversi.
3. Base migration `20260911110000` terpasang dan tidak diedit.
4. Forward-fix preflight dijalankan tanpa blocker, lalu migration additive
   `20260911111000` terpasang.
5. User mengonfirmasi corrected rollback-only behavior sukses.
6. User mengonfirmasi forward-fix postflight dan base postflight seluruhnya
   PASS.
7. Public Apply tetap belum dibuka. Gate berikutnya adalah attachment Draft
   hasil cutover ke sesi Retail nyata tanpa repricing pada sekadar membuka.

## Evidence lokal

- Parenthesis/delimiter ketiga SQL seimbang.
- `git diff --check` tidak menemukan whitespace error; output hanya warning
  normalisasi line ending CRLF.
- Migration SHA-256:
  `6a57a7c9f9ff0fce2ff3fef95e02e1cf0ea28e5c3a36d146b7bc040e9fcf2442`.
- Corrected behavioral SHA-256:
  `056d23b2a487ebfce214a2d11ff0851ab65149f598e3ac1270fbd2461b65763b`.
- Base postflight SHA-256:
  `c2265430f3256d0586619e978f147dc46d44a0fa6325b08a673a4ff15602fab7`.
- Forward-fix preflight SHA-256:
  `f0d5309cdaeff750170e59da32ef28b2319f6fffa37c83048d448fb02610a6f4`.
- Forward-fix migration SHA-256:
  `af01850d1f5b0e91f7b4960dbba79f32e4ec18deb487d98b4e92139655f44ad2`.
- Forward-fix postflight SHA-256:
  `fea855f2cff6c3b02c2b0a8f8a9667e0c1b985792af6d4c68cd629be733b8a42`.

## Rollback/forward-fix

Migration base telah masuk ledger dan tidak diedit. Defect operation/audit FK
dikoreksi oleh forward-fix additive `20260911111000` dengan exact guarded
replacement; bila definition berbeda migration berhenti sebelum perubahan.
Public Apply dan Company mode switch tetap tidak tersedia. Draft
`BACKOFFICE_CUTOVER` belum boleh memakai sesi POS palsu; attachment ke sesi
Retail nyata menjadi gate lanjutan sebelum client switch.

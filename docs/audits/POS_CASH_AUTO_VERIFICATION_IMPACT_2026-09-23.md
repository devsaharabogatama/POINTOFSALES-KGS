# POS Cash Auto Verification - Impact Map

Status: **LOCAL READY / PREFLIGHT HARNESS FIXED / PRODUCTION RERUN REQUIRED**

Production preflight sebelumnya menemukan `pos_cash_auto_runtime_anchor=BLOCKER`
karena anchor `confirm=0`. Root cause sudah dibuktikan dari migration chain aktif:
fungsi publik adalah revision-aware wrapper dan payment capture berada pada
`private.confirm_pos_sales_order_before_revision_core`. Preflight lama keliru
mencari capture langsung di wrapper publik. Assertion kini memvalidasi kedua
lapisan secara eksplisit dan migration guard/postflight memakai kontrak yang
sama. Migration belum dijalankan; preflight yang sudah diperbaiki wajib dirun
ulang sebelum rollout.

## Business contract

- Hanya Payment Method dengan `settlement_route = CASH_DRAWER` pada alur POS
  yang diselesaikan otomatis sebagai `VERIFIED` pada transaksi konfirmasi Order.
- Transfer dan seluruh metode non-Cash tetap `PENDING` dan tetap memakai
  maker-checker Finance.
- Cash Drawer `IN` tetap menjadi bukti fisik penerimaan uang. Auto-verification
  membuat satu Financial Event `SALE_PAYMENT_VERIFIED` berstatus `HOLD`; jurnal
  tetap dibentuk oleh controlled Finance posting yang sudah ada.
- Split payment memproses setiap kaki secara independen: Cash otomatis,
  non-Cash tetap antre Finance.

## Impact map

| Area | Direct impact | Invariant yang dipertahankan |
| --- | --- | --- |
| POS confirm | Capture Cash ditutup otomatis setelah Drawer `IN` tercatat | Satu request per `clientPaymentKey`, retry exact, payload conflict tetap ditolak |
| Finance verification | Workspace dan counter manual tidak memuat route Cash | Transfer/non-Cash dan maker-checker tidak berubah |
| Finance event | Dibuat satu event `HOLD` source-linked untuk Cash | Tidak ada auto-post jurnal; mapping COA/periode tetap divalidasi saat posting |
| Cash Drawer | Tidak ada Drawer movement tambahan saat verifikasi | `IN` tetap satu kali; cancel memakai satu `OUT` reversal |
| Cancellation | Auto-Cash yang event-nya masih `HOLD` dapat dibatalkan sebelum dispatch | Event `POSTED`, dispatch yang sudah mulai, dan payment manual tetap fail-closed |
| Revision | Cash yang sudah diterima tetap dianggap fakta keuangan | Revisi source Order tetap ditolak bila payment sudah `VERIFIED` |
| Session close | Tidak lagi bergantung pada review Cash manual | Runtime close asynchronous yang ada tidak diubah |
| Existing pending Cash | Hanya row dengan source Drawer/category/scope valid yang dibackfill | Row ambigu menghentikan migration; histori final tidak ditulis ulang |

## Downstream and regression risks

- `sales_payment_verification_requests`, audit, Cash Drawer, Financial Event,
  cancellation read-model, Finance navigation counter, dan UI queue terdampak.
- Stock, FIFO, Reservation, Dispatch, RO/PO, Backoffice Sales, Return/Refund,
  gross-discount accounting, dan pengaturan auto-request saat tutup sesi berada
  di luar scope dan tidak boleh berubah.
- Event Cash yang sudah `POSTED` tidak boleh dibatalkan dengan mengubah histori;
  koreksinya tetap harus melalui reversal/refund source-linked.
- Existing pending Cash dari sesi tertutup boleh diklasifikasikan otomatis bila
  Drawer `IN` exact masih valid. Pembatalan sesudahnya tetap memerlukan sesi
  Cashier aktif di Store yang sama untuk mencatat uang keluar.

## Evidence required before claiming completion

1. Read-only preflight seluruhnya `PASS` (baris `INFO` bukan blocker).
2. Guarded migration terpasang satu kali.
3. Rollback-only behavior membuktikan Cash, transfer, split, retry, cancellation,
   stale/final boundary, tenant scope, dan tidak meninggalkan fixture.
4. Read-only postflight seluruhnya `PASS`.
5. Client deploy dari commit yang sama.
6. Authenticated smoke: Cash-only, transfer-only, split, close session,
   pre-dispatch cancel, queue Finance, dan controlled posting.

Status harus dilaporkan terpisah sebagai `LOCAL READY`, `DATABASE LIVE`,
`CLIENT DEPLOYED`, `SMOKE PASS`, dan `UAT PASS`.

# Finance AR and Period Completion Plan

Status: **F1–F4A database PASS; F4B posting policy, universal controlled queue,
automatic final-event runtime, Backoffice policy UI, dan regression local-ready
serta menunggu manual Supabase rollout/controlled backlog closure**.

## Keputusan bisnis

1. Pembuatan Accounting Period adalah kebijakan per Company: `MANUAL` atau
   `AUTOMATIC`. Mode otomatis memastikan bulan berjalan dan bulan berikutnya
   tersedia, tetapi tidak pernah membuka kembali periode `LOCKED`.
2. Tanggal order TEMPO adalah tanggal bisnis. Waktu pembuatan, perubahan, dan
   posting tetap timestamp audit aktual. Membuka ulang Draft tidak dianggap
   sebagai pemilihan tanggal historis baru.
3. Jatuh tempo boleh lebih awal daripada tanggal pembayaran aktual, tetapi
   tidak boleh lebih awal daripada tanggal order secara tanggal bisnis Company.
4. Pembayaran piutang Customer harus menjadi dokumen tersendiri dengan alokasi
   invoice, partial payment, exact retry, bukti, dan jurnal `Dr Cash/Bank; Cr AR`.
5. Backorder yang baru dicatat setelah pembayaran tetap menggunakan tiga waktu:
   tanggal order, tanggal pembayaran aktual, dan timestamp input/audit.
6. Selisih pembayaran yang belum dialokasikan menjadi advance/Customer Balance
   hanya melalui keputusan eksplisit; tidak boleh otomatis dianggap pendapatan.
7. Aging, statement, outstanding invoice, unapplied receipt, dan export wajib
   bersumber dari dokumen final serta allocation ledger, bukan cache client.
8. Posting otomatis merupakan policy terpisah. Sampai F4 selesai dan behavioral
   test lulus, default dan runtime tetap `CONTROLLED`.

## Fase

- **F1 - Period policy dan TEMPO date correctness:** policy Company, auto-create
  current/next period, resume intent, business-date due/delivery validation.
- **F2 - Customer Receipt / AR allocation:** schema, guarded runtime, audit,
  payment method/account snapshots, partial/multi-invoice allocation, reversal.
- **F3 - Historical collection:** payment date aktual, backorder after payment,
  advance/unapplied receipt, Customer Balance settlement, idempotent journal.
- **F4 - Finance UX/reporting:** outstanding invoice, aging, statement/export,
  reconciliation, controlled/automatic posting policy, end-to-end regression.

F4B tidak mengaktifkan `AUTOMATIC` saat migration. Lima Company existing tetap
`CONTROLLED`; backlog HOLD dipreview, disetujui, dan diproses dahulu melalui
queue universal. Mode otomatis memakai deferred final-event trigger dan
exception retry, sedangkan event `CANCELED` tetap tidak diposting.

Controlled backlog pertama menemukan compatibility gap pada Sale TEMPO:
runtime lama hanya menjumlahkan Payment legs dan menolak unpaid/partial TEMPO.
Forward-fix F4B.1 menambahkan debit `CUSTOMER_RECEIVABLE` dari immutable Sale
dan Event receivable snapshot, dengan invariant `payment + receivable = grand
total + surcharge`. Event gagal tetap HOLD dan hanya diproses ulang lewat queue
Controlled setelah migration dan behavioral test lulus.

## Invariant

- Tidak ada perubahan pada Sale POSTED untuk mencatat pembayaran belakangan.
- Tidak ada direct browser write ke dokumen receipt, allocation, ledger, period,
  atau journal.
- Total allocation tidak boleh melebihi receipt atau outstanding invoice.
- Maker/checker dan Company boundary ditegakkan oleh RPC server.
- Semua efek jurnal harus balance, source-linked, idempotent, dan period-aware.

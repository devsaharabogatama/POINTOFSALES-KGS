# Customer Receipt Credit Note Outstanding Alignment

## Outcome

Finance Penerimaan Customer memakai outstanding yang sama dengan Invoice:

`Invoice awal - Credit Note POSTED (AR reduction) - Penerimaan POSTED`.

Invoice yang sudah habis oleh Credit Note tidak ditawarkan lagi. Invoice parsial
menampilkan nilai koreksi Retur dan hanya dapat dialokasikan sampai nilai bersih.

## Impact map

- Direct: workspace Penerimaan Customer, Save Draft, dan Post recheck untuk
  Invoice Backoffice serta retained Retail.
- Downstream: modal Finance dan laporan Aging memakai angka canonical yang sama.
- Stock/FIFO: tidak berubah. Customer Return Receipt tetap satu-satunya authority
  `RESTOCK`/`DESTROY`.
- Finance: tidak membuat atau mengubah Credit Note, Receipt, Journal, AR, Refund,
  atau transaksi historis. Hanya reader dan batas alokasi yang disejajarkan.
- Compatibility: system WALK-IN Backoffice exception, Customer Balance, mixed
  Retail/Backoffice receipt, date-effective calculation, permission, retry,
  idempotency, dan stale-version contract dipertahankan.
- Concurrency: Post mengunci source Sale/Invoice lalu menghitung ulang outstanding;
  Draft lama yang melampaui nilai bersih ditolak saat Post dan harus diedit.

## Urutan Production

1. Jalankan [preflight](../../supabase/diagnostics/customer_receipt_credit_note_outstanding_preflight.sql).
2. Berhenti jika ada `BLOCKER`.
3. Jalankan [migration](../../supabase/migrations/20260919110000_customer_receipt_credit_note_outstanding_alignment.sql).
4. Jalankan [behavior test](../../supabase/tests/customer_receipt_credit_note_outstanding_behavior.sql); seluruh write di-rollback.
5. Jalankan [postflight](../../supabase/diagnostics/customer_receipt_credit_note_outstanding_postflight.sql).
6. Deploy client setelah seluruh check non-`INFO` berstatus `PASS`.

## Smoke

1. Buka Penerimaan Customer untuk Customer yang mempunyai Invoice diretur.
2. Pastikan `Koreksi retur` sama dengan Credit Note posted.
3. Pastikan `Sisa piutang` sama dengan Invoice awal dikurangi koreksi dan pembayaran.
4. Invoice dengan sisa nol tidak muncul.
5. Coba alokasi parsial dan penuh tepat sisa; keduanya dapat disimpan/diposting.
6. Draft lama yang lebih besar dari sisa harus ditolak dengan pesan outstanding berubah.
7. Ulangi untuk satu sumber Backoffice dan satu retained Retail.

## Rollback / forward-fix

Tidak menghapus data. Bila ditemukan mismatch, hentikan client rollout dan
forward-fix reader/guard setelah membandingkan source Credit Note dan Receipt.
Jangan menghapus atau mengubah Invoice, Credit Note, Receipt, Journal, atau Stock.

## Status

- Local: TypeScript, targeted ESLint, production build (87 pages), dan diff
  check `PASS`.
- Database/client/smoke/UAT: belum dijalankan.

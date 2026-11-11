# Backoffice AR Credit Note Replacement Rollout

Status: local automated gates PASS; Production belum disentuh.

## Urutan rollout kelak

1. Freeze commit dan jalankan replacement preflight SELECT-only. File ini harus
   mengembalikan tepat enam baris dalam satu result set. Output yang hanya
   berisi `business_boundary` tidak cukup untuk mengizinkan migration.
2. Bila mandatory rows PASS dan state `NOT_INSTALLED`, jalankan migration
   `20261110100000_backoffice_ar_credit_note_replacement_invoice.sql`.
3. Jalankan replacement postflight dan rollback-only behavior. Postflight
   harus mengembalikan tepat enam baris dalam satu result set; satu baris
   `business_boundary` saja bukan bukti installation contract.
4. Jalankan Receipt Company-date preflight SELECT-only.
5. Bila state `NOT_INSTALLED`, jalankan migration
   `20261110110000_backoffice_customer_receipt_company_date.sql`.
6. Jalankan date postflight, cumulative Task 3 behavior, lalu postflight Task
   2â€“6.
7. Deploy client hanya setelah database gates ditutup.
8. Jalankan authenticated smoke dan UAT sesuai
   `BACKOFFICE_AR_FINANCE_END_TO_END_LOCAL_UAT_2026-11-10.md`.
9. Jalankan Production legacy inventory SELECT-only. Candidate nonzero wajib
   direview per baris; tidak boleh auto-reclassify.

Dependency Task 2â€“5 yang telah live bersifat immutable: jangan edit, hapus
ledger, atau rerun file applied.

## Stop conditions

Hentikan pada partial/inconsistent state, digest berbeda, runtime queue tidak
aman, behavior/postflight/smoke FAIL, akses lintas tenant, efek Stock/FIFO tak
terduga, tax-enabled Company masuk flow, atau RETAINED_RETAIL compatibility
belum terbukti. Kembali ke audit read-only dan buat forward migration.

## Forward-fix note

Migration forward-only. Setelah applied, jangan rollback dengan mengedit file
lama atau ledger. Sebelum client deploy, hentikan rollout dan buat forward fix.
Sesudah deploy, nonaktifkan entry point bila diperlukan, pertahankan audit/data
yang sudah tercatat, lalu buat forward fix transactional/idempotent.

Laporkan terpisah: `AUDIT COMPLETE`, `LOCAL READY`, `DATABASE LIVE`, `CLIENT
DEPLOYED`, `SMOKE PASS`, dan `UAT PASS`. Satu status tidak membuktikan status
berikutnya.

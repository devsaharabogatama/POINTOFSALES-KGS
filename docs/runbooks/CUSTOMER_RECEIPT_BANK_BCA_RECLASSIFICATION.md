# Customer Receipt BANK BCA Reclassification

Status awal: `LOCAL READY`; database Production belum diubah oleh agent.

## Scope

- Company: KMS, SMS, LSM.
- Hanya Customer Receipt `DIRECT_BANK`; Cash tetap memakai Kas/Laci.
- Exact mapping `SALE_PAYMENT / BANK` memakai `1010100-1 BANK BCA` untuk seluruh
  tanggal transaksi.
- Jurnal lama dipertahankan; reklasifikasi per Receipt: Debit BANK BCA, Kredit
  akun Bank lama.

## Urutan manual SQL Editor

Jalankan setiap file secara penuh, jangan `Run selected`:

1. [Preflight](../../supabase/diagnostics/customer_receipt_bank_bca_reclassification_preflight.sql)
2. [Migration](../../supabase/migrations/20260918140000_customer_receipt_bank_bca_reclassification.sql)
3. [Behavioral test](../../supabase/tests/customer_receipt_bank_bca_reclassification_behavior.sql)
4. [Postflight](../../supabase/diagnostics/customer_receipt_bank_bca_reclassification_postflight.sql)

Berhenti sebelum migration bila ada `BLOCKER`. Setelah migration, berhenti bila
behavior bukan `PASS` atau postflight menghasilkan `BLOCKER/FAIL`.

## Client

`FinanceMasterView` sekarang mengubah nilai `datetime-local` browser menjadi ISO
UTC sebelum request. Deploy client diperlukan agar mapping berikutnya tidak
bergeser +7 jam.

## Smoke setelah rollout

1. Buat Draft Penerimaan Customer dengan metode `DIRECT_BANK` pada salah satu
   Company target.
2. Post dan pastikan jurnal Debit `BANK BCA`, Kredit `Piutang Customer`.
3. Pastikan Receipt Cash tetap Debit akun Kas/Laci.
4. Periksa Receipt bank historis: jurnal sumber tetap ada dan jurnal
   reklasifikasi tertaut ke nomor Receipt dengan nilai balance.
5. Ulangi POST/reload; tidak boleh terbentuk jurnal ganda.

## Forward-fix

Jangan update/delete jurnal POSTED. Jika target atau nilai salah, hentikan
posting dan buat reversal source-linked atas jurnal reklasifikasi pada periode
terbuka, lalu buat replacement yang benar.

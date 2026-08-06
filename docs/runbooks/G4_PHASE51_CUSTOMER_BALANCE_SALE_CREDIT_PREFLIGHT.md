# G4 Phase 51 — Customer Balance Sale Credit Preflight

## Tujuan

Mengaudit kesiapan server untuk menyimpan kelebihan Transfer atau kembalian
Cash sebagai Saldo Customer. Diagnostic ini SELECT-only dan belum mengubah
checkout maupun saldo.

## Urutan Roadmap Customer Balance

1. Phase 49 — ledger, lifecycle, correction maker-checker: complete.
2. Phase 50 — Backoffice correction/statement UI: local-ready, smoke manual.
3. Phase 51 — preflight Sale overpayment credit: fase aktif ini.
4. Phase 52 — atomic server credit dari Payment/Sale ke ledger.
5. Phase 53 — UI POS `Kembalikan` atau `Simpan sebagai saldo`.
6. Phase berikutnya — penggunaan seluruh saldo lama sebagai tender checkout.
7. Refund-to-balance, Offline Customer Balance, Ketul, dan exceptional
   settlement tetap gate terpisah.

## Menjalankan

Jalankan seluruh file berikut pada Supabase SQL Editor:

```text
supabase/diagnostics/g4_phase51_customer_balance_sale_credit_preflight.sql
```

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER`: berhenti; source data/account/tenant contract harus diperbaiki.
- `REVIEW`: kirim output; histori overpayment non-Cash tidak boleh dianggap
  otomatis sebagai saldo.
- `SETUP`: expected untuk tiga snapshot Payment, ledger source
  `SALE_OVERPAYMENT`, dan atomic Sale runtime yang memang belum dibuat.
- `PASS`/`INFO`: aman.

Cash change historis tetap dianggap sudah dikembalikan kepada Customer. Fase
berikut tidak melakukan backfill saldo dari data lama tanpa keputusan bisnis
eksplisit.

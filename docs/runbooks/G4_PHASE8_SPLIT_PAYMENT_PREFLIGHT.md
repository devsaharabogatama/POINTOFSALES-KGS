# G4 Phase 8 — Split Payment Preflight

## Tujuan

Mengaudit kesiapan split payment online setelah Sale Draft list/edit-lock PWA
lulus. Preflight tidak membuka offline queue, Customer Balance, Ketul Offset,
settlement, refund, atau Finance reconciliation.

## Menjalankan

Jalankan seluruh file berikut pada Supabase SQL Editor:

```text
supabase/diagnostics/g4_phase8_split_payment_preflight.sql
```

Kirim seluruh hasil `check_name,status,details`.

## Expected Baseline

- dependency, server array loop, fee configuration, posted total, snapshot,
  tender/change, dan browser write boundary harus `PASS`;
- `active_store_split_method_readiness` boleh `BACKFILL` bila Store belum
  memiliki minimal dua metode aktif dari tipe berbeda;
- `duplicate_method_in_posted_sale` hanya boleh `REVIEW` bila memang ada
  histori lama yang perlu keputusan eksplisit;
- `payment_leg_identity_schema_state` diharapkan `SETUP` sebelum forward
  foundation karena `client_payment_key` belum canonical.

## Boundary

Preflight ini SELECT-only. Jangan mengubah `sales_payments`, payload Draft,
Payment Method, posted Sale, stock, FIFO, financial event, atau receipt untuk
“membersihkan” output.

Setelah output bersih, next safe step adalah forward-only payment-leg identity
dan validator server, lalu PWA split-payment UI. Offline tetap gate terpisah.

# ACP-6A Expense Permission Preflight

**Status:** SELECT-ONLY READY  
**Permission key:** `finance.expenses`

## Tujuan

Memotret runtime Expense sebelum custom permission Finance diaktifkan. Preflight
ini tidak mengubah schema, data, grant, function, status permission, drawer,
Finance event, atau jurnal.

Scope yang dinilai:

- Category dan approval policy;
- Draft/Submit/Approve/Reject/Cancel;
- Cash dan non-Cash disbursement;
- settlement, return, serta additional disbursement;
- pemisahan Backoffice dan PWA open-session;
- cash drawer, idempotency, outstanding, tenant, dan Finance HOLD;
- direct table/RPC boundary dan target composed read.

## Cara Menjalankan

Jalankan:

`supabase/diagnostics/acp_phase6a_expense_permission_preflight.sql`

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER`: hentikan; data/schema/security harus diperbaiki dahulu.
- `REVIEW`: keputusan/boundary yang harus dipertahankan pada enforcement.
- `SETUP`: capability/read model belum dipasang dan merupakan target phase.
- `PASS`: invariant siap.
- `INFO`: inventory saja.

Jangan menjalankan migration ACP-6A sebelum seluruh output live direview.

## Boundary Tetap

- Backoffice VIEW tidak memberi authority drawer kepada Cashier;
- Kasir hanya bertindak melalui sesi OPEN dan Store yang sah;
- Cash saja mengubah expected drawer;
- non-Cash disbursement tetap Finance/Admin-authorized;
- approval, settlement review, additional approval, dan final disbursement tidak
  boleh disatukan menjadi satu capability longgar;
- Draft/Submitted tidak membuat final effect;
- dokumen setelah disbursement bersifat append-only;
- ACP tidak melepaskan event Finance HOLD dan tidak membuat jurnal baru.

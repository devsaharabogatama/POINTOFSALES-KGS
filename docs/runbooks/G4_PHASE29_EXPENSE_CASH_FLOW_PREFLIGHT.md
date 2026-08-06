# G4 Phase 29 — Expense dan Arus Kas Non-Penjualan Preflight

## Status

`READY FOR MANUAL PREFLIGHT`

## Tujuan

Mengaudit live state sebelum canonical Expense dibangun. Fase ini tidak
membuat schema, data, RPC, grant, atau UI.

Kontrak bisnis mengikuti `docs/POS_EXPENSE_CASH_FLOW_SPEC.md`:

- Cash Advance legacy tidak dipertahankan sebagai jenis bisnis;
- satu Expense menyimpan requested, disbursed, actual, returned, outstanding;
- hanya Cash yang mengubah expected drawer;
- Transfer/Bank menunggu konfirmasi Finance;
- approval dapat dikonfigurasi, tetapi audit selalu wajib;
- Expense tidak membuat stock movement;
- Finance Event boleh dibuat `HOLD`, sedangkan jurnal G6 tetap tertutup.

## Cara menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor dan kirim seluruh output:

`supabase/diagnostics/g4_phase29_expense_cash_flow_preflight.sql`

File hanya berisi satu query `WITH ... SELECT` dan menghasilkan aggregate
counts tanpa nama kategori, orang, atau data bisnis.

## Interpretasi

- `BLOCKER`: jangan membuat migration Expense sebelum penyebab diselesaikan;
- `REVIEW`: legacy trigger atau mapping Finance perlu keputusan eksplisit;
- `BACKFILL`: data legacy perlu dipetakan ke canonical document/event;
- `SETUP`: canonical schema belum ada dan expected pada preflight pertama;
- `PASS`: invariant live aman;
- `INFO`: inventory untuk desain rollout, bukan kegagalan.

Expected pada instalasi saat ini:

- `canonical_expense_schema_state = SETUP`;
- legacy trigger dapat muncul `REVIEW` walaupun tidak ada row;
- entitlement `expense_enabled` dapat masih zero-row;
- Finance account readiness boleh `REVIEW`, tetapi seluruh kategori transaksi
  Expense/Cash In dan metode Cash Store aktif harus siap sebelum rollout.

## Batas fase berikut

Setelah output diterima, migration foundation harus tetap additive dan menutup
direct browser write. Jangan membuka Offline Expense, Deposit, jurnal Finance,
internal cash transfer, Customer Balance settlement, atau G5 Purchasing pada
rollout Expense pertama.

# ACP-5H Sales Return Permission Preflight

**Status:** SELECT-ONLY READY — manual Supabase execution pending  
**Gate:** ACP-5H, penutup ACP-5 Contacts/Purchase/Sales  
**Permission key:** `sales.sales_returns`

## Tujuan

Membuktikan boundary Sales Return sebelum enforcement tanpa mengubah runtime:

- Backoffice list/detail memakai `VIEW`; final approval memakai `POST` dan
  Draft cancellation memakai `CANCEL_FINAL`;
- lifecycle tetap `DRAFT → POSTED` atau `DRAFT → CANCELED`; ACP tidak menambah
  status approval baru;
- Cashier mencari Sale dan membuat Draft hanya melalui open Session/Store scope;
- PWA tidak lagi perlu membaca Sale/Return/Warehouse table untuk menghitung
  refundable amount, ongkir, atau remaining quantity;
- final Post tetap atomik, idempotent, source-quantity bounded, memulihkan FIFO
  asli, dan membuat satu Finance HOLD event;
- Bundle Return memakai immutable component allocation;
- delivery-fee refund tetap eksplisit dan hanya valid menurut kontrak full
  remaining Return.

## Yang Tidak Dibuka

- tidak ada DDL, DML, grant, RLS, function, audit, API, atau UI yang diubah;
- tidak mengubah POS checkout, Sale, Product, Bundle, Stock, Payment, atau Tax;
- tidak melepaskan Finance HOLD atau membuat Journal;
- tidak membuka Cashier final Post maupun Backoffice Draft creation;
- tidak mencabut direct SELECT sampai PWA dan Backoffice berpindah bersama.

## Cara Menjalankan

Jalankan:

`supabase/diagnostics/acp_phase5h_sales_return_permission_preflight.sql`

Kirim seluruh output `check_name,status,details`.

- `BLOCKER`: berhenti dan perbaiki prerequisite/invariant dahulu.
- `REVIEW`: keputusan authority yang harus dipertahankan.
- `SETUP`: target enforcement berikutnya, bukan error.
- `PASS`: invariant live sesuai baseline.
- `INFO`: inventaris saja.

## Target Enforcement Setelah Preflight Bersih

1. composed Backoffice RPC guarded `VIEW`;
2. PWA source/Draft RPC terpisah dan open-session scoped;
3. public Post wrapper guarded `POST` tanpa mengubah atomic core;
4. public Cancel wrapper guarded `CANCEL_FINAL` sambil mempertahankan creator/
   Store-manager scope;
5. direct SELECT lima tabel Return ditutup setelah consumer cutover;
6. behavior menguji preset, tenant, Cashier isolation, quantity/refund/FIFO,
   Bundle, ongkir, idempotency, Finance HOLD, dan no-double-effect.

## Rollback

Preflight ini SELECT-only dan tidak memerlukan rollback. Jangan membuat atau
menjalankan migration enforcement bila ada `BLOCKER`.

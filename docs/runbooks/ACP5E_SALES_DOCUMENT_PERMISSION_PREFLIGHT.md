# ACP-5E Sales Document Permission Preflight

**Status:** SELECT-ONLY READY — manual Supabase execution pending  
**Gate:** ACP-5E, bagian dari ACP-5 Contacts/Purchase/Sales  
**Permission key:** `sales.sales_documents`

## Tujuan

Membuktikan boundary Invoice Penjualan dan Surat Jalan sebelum enforcement:

- Backoffice list/detail/print memakai capability `VIEW`;
- perubahan status Surat Jalan memakai `MANAGE`;
- export snapshot final memakai `EXPORT` secara eksplisit;
- POS checkout/finalization, Sales Return, dan Finance tetap memiliki authority
  terpisah;
- Invoice dan Surat Jalan tetap snapshot final tenant-scoped tanpa efek Stock,
  Payment, atau Finance kedua;
- direct table read baru ditutup setelah Backoffice dan PWA pindah ke RPC yang
  sempit.

## Yang Tidak Dibuka

- tidak ada schema, grant, RLS, function, data, atau UI yang diubah;
- tidak ada import untuk dokumen Sales final;
- tidak mengubah checkout, Return, payment, delivery fee, Stock, atau jurnal;
- tidak memproses Financial Event `HOLD`;
- tidak mencabut read tabel Sale bersama yang masih dipakai POS/Return.

## Cara Menjalankan

Jalankan satu file berikut di Supabase SQL Editor:

`supabase/diagnostics/acp_phase5e_sales_document_permission_preflight.sql`

Kirim seluruh output `check_name,status,details`.

- `BLOCKER`: berhenti; perbaiki data/schema/privilege lebih dulu.
- `REVIEW`: keputusan/cutover yang memang harus dijaga saat enforcement.
- `SETUP`: target implementasi berikutnya, bukan kegagalan data.
- `PASS`: invariant live sesuai baseline.
- `INFO`: inventaris saja.

## Target Enforcement Setelah Preflight Bersih

1. satu composed RPC list/detail Backoffice yang memerlukan `VIEW`;
2. RPC print ter-audit memerlukan `VIEW`;
3. status `DISPATCHED`/`DELIVERED`/`CANCELED` memerlukan `MANAGE`;
4. export final snapshot memerlukan `EXPORT`;
5. PWA final Invoice memakai posted-Sale/open-session path sendiri;
6. Sales Return dan Finance memakai reference/evidence API masing-masing;
7. direct SELECT empat tabel dokumen dicabut hanya sesudah semua consumer aktif
   dipindahkan;
8. behavior wajib menguji restriction preset, direct RPC denial, dan isolasi
   dua Company tanpa menggandakan efek Sale.

## Rollback

Preflight ini SELECT-only sehingga tidak memerlukan rollback. Jika output
bermasalah, jangan membuat atau menjalankan migration enforcement.

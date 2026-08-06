# G4 Phase 36 — Expense Settlement Preflight

**Status:** READY FOR MANUAL PREFLIGHT  
**Scope:** SELECT-only readiness audit untuk actual Expense, pengembalian dana,
outstanding, dan additional disbursement.

## Boundary

Fase ini tidak membuat atau mengubah data. Fase ini juga belum membuka:

- input biaya aktual atau review settlement;
- pengembalian Cash/non-Cash dan Cash In;
- additional disbursement;
- Offline Expense, Deposit, atau jurnal final G6.

## Menjalankan preflight

1. Buka Supabase SQL Editor.
2. Jalankan seluruh
   `supabase/diagnostics/g4_phase36_expense_settlement_preflight.sql`.
3. Ekspor/kirim seluruh hasil `check_name,status,details`.

Interpretasi:

- `BLOCKER`: hentikan; data live atau dependency belum aman.
- `REVIEW`: kirim hasilnya untuk menilai scope backfill/operasional.
- `SETUP`: expected untuk schema/RPC settlement yang memang belum dibuka.
- `PASS`: invariant saat ini aman.
- `INFO`: inventaris, bukan kegagalan.

## Fokus audit

- dependency Phase 34 dan direct-write boundary;
- rekonsiliasi total dokumen dengan event append-only disbursement,
  settlement, dan return;
- lifecycle `DISBURSED/PARTIALLY_SETTLED/SETTLED`;
- coverage Financial Event dan Cash drawer untuk histori yang sudah ada;
- kesiapan akun kategori Expense dan sesi penerima Cash return;
- aging/outstanding live;
- gap schema, enum, dan guarded RPC untuk fase foundation berikutnya.

## Expected result pada rollout baru

Beberapa check schema/runtime kemungkinan berstatus `SETUP`. Itu bukan alasan untuk
mengubah database secara manual. Semua check `BLOCKER` harus nol sebelum
foundation settlement dirancang dan dijalankan.

## Recovery

Tidak ada rollback karena file ini SELECT-only. Jika query gagal karena nama
kolom/schema, hentikan dan perbaiki diagnostic dari migration contract; jangan
mengubah live schema agar diagnostic terlihat lulus.

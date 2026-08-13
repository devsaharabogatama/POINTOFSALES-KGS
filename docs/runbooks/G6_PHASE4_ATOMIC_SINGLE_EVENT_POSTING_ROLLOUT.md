# G6 Corrective Phase 4 Atomic Single-Event Posting Rollout

## Scope

Phase ini membuka engine posting **satu event** secara atomik dengan kontrak
awal `STOCK_OPENING`:

- debit `INVENTORY_ASSET` = `amounts.inventoryDebit`;
- credit `OPENING_BALANCE_CLEARING` = `amounts.openingBalanceCredit`;
- kedua nominal wajib positif, sama dengan `opening_stock_documents.total_cost`,
  dan menghasilkan jurnal balanced;
- akun berasal dari approved effective-dated mapping, bukan nomor COA hard-code;
- periode terkunci memakai periode terbuka berikutnya sebagai
  `PRIOR_PERIOD_ADJUSTMENT`, dengan tanggal event asli tetap disimpan;
- event berubah `HOLD -> POSTED` hanya setelah jurnal header/line selesai;
- replay event yang sudah POSTED mengembalikan journal yang sama.

Migration tidak memproses event existing. Event Sales, Payment, Purchase,
Expense, Return, Deposit, dan event lain tetap `HOLD`; historical queue tetap
Corrective Phase 5.

## Urutan wajib

Hentikan pada error pertama.

1. Jalankan migration:
   `supabase/migrations/20260810200000_g6_phase4_atomic_single_event_posting.sql`.
2. Jalankan postflight:
   `supabase/diagnostics/g6_phase4_atomic_single_event_posting_postflight.sql`.
3. Semua row selain inventory harus `PASS` dan `violation_rows=0`.
4. Jalankan behavioral test:
   `supabase/tests/g6_phase4_atomic_single_event_posting_tests.sql`.
5. Pastikan muncul notice `TEST PASSED` dan transaction berakhir `ROLLBACK`.

Jangan menjalankan routine posting terhadap event bisnis live pada phase ini.
Behavioral test sudah membuktikan posting menggunakan fixture rollback-safe.

## Yang diuji

- provisioning mapping/rule untuk Company baru;
- source document dan amount snapshot tidak boleh berbeda;
- exact satu approved rule-set/effective date;
- exact satu active account mapping per required function;
- Accounting Period OPEN/REOPENED dan prior-period routing;
- seluruh line diselesaikan dan balanced sebelum journal insert;
- tenant isolation dan role boundary;
- exact idempotent replay tanpa journal duplicate;
- unsupported event tetap HOLD, tanpa journal, dengan posting exception;
- browser tidak mendapat direct write ke Event/Journal/Line.

## Compatibility dan recovery

- additive: journal legacy tidak dihapus atau diubah;
- existing event HOLD tidak diproses oleh migration;
- source document, Stock/FIFO/Movement, dan business status tidak dimutasi;
- jika rollout bermasalah setelah migration applied, hentikan pemanggilan RPC
  baru. Jangan drop journal atau mengubah POSTED kembali menjadi HOLD;
- perbaikan setelah applied harus forward-only dengan version baru.

## Exit

Phase 4 baru `COMPLETE` setelah migration, postflight, dan behavioral test
dikonfirmasi user PASS. Next safe step adalah Phase 5 preflight untuk controlled
active-Company queue dan approved historical backfill. Tidak ada batch posting
sebelum preview dan approval Phase 5 tersedia.

# G6 Corrective Phase 5 — Controlled Queue Preflight

## Tujuan

Memetakan scope queue dan historical `HOLD` secara read-only sebelum schema,
approval, atau batch processor dibuat. Phase ini tidak memposting event.

## Boundary yang dikunci

- satu queue run hanya boleh untuk satu active Company;
- preview dan approval wajib terjadi sebelum processing;
- browser/operator tidak boleh mengirim Company nullable atau lintas tenant;
- satu event gagal tidak boleh meninggalkan jurnal parsial;
- retry harus memakai identity event/version yang sama;
- event `POSTED` dan jurnal existing tidak boleh dikembalikan ke `HOLD` atau
  dihapus;
- runtime Phase 4 saat ini hanya mendukung kontrak `STOCK_OPENING`.
  Kontrak event lain tetap `DEFERRED`, bukan dipaksakan masuk batch.

## Langkah manual

1. Buka Supabase SQL Editor pada project target.
2. Jalankan seluruh file
   `supabase/diagnostics/g6_phase5_controlled_queue_preflight.sql`.
3. Kirim seluruh hasil `check_name,status,details`.

## Interpretasi hasil

- `BLOCKER`: hentikan; jangan membuat atau menjalankan migration Phase 5.
- `REVIEW`: perlu keputusan berbasis live-state sebelum desain queue dikunci.
- `BACKFILL`: scope data/config yang memang harus dipreview dan disetujui.
- `SETUP`: object queue belum ada dan merupakan expected baseline.
- `DEFERRED`: event di luar kontrak posting Phase 4; tidak boleh diproses.
- `PASS`/`INFO`: aman atau inventory saja.

Expected baseline saat ini adalah tiga relation dan tiga routine queue masih
`SETUP`, historical `STOCK_OPENING` dapat muncul sebagai `BACKFILL`, dan event
lain dapat muncul sebagai `DEFERRED`. `BLOCKER` harus nol.

## Rollback

Tidak ada rollback. Diagnostic ini satu statement `SELECT` dan tidak mengubah
schema, data, privilege, session, atau event.

## Next safe step

Setelah seluruh output direview dan `BLOCKER` nol, buat Phase 5 foundation yang
menyimpan immutable preview, approval snapshot, per-event result, serta
processor satu active Company per request. Jangan memproses historical HOLD
di dalam migration.

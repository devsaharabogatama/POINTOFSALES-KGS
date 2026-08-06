# G4 Phase 12 — Offline Submission/Sync Preflight

## Tujuan

Audit ini menentukan apakah database existing aman untuk menerima kontrak
submission offline dan atomic sync posting. File SQL hanya membaca aggregate
state dan tidak membuka endpoint/PWA offline.

## Yang diaudit

- dependency Online Sale, Payment-Leg identity, dan Offline Allowance;
- entitlement tetap disabled;
- submission envelope kosong/valid dan identity tidak ambigu;
- reservation aktif tidak melebihi on-hand;
- Stock–Movement–FIFO tetap reconcile;
- Cash dan metode elektronik eligible;
- Transaction Category `SALE_POSTED`;
- kesiapan account function/system event payment exception;
- gap consumption link, sync exception, payment exception;
- gap snapshot channel/time/price variance/payment verification;
- gap public submit, private atomic processor, dan status acknowledgement;
- Session close guard dan browser direct-write closure.

## Cara menjalankan

1. Pastikan migration/test/regression Phase 11 sudah lulus.
2. Pastikan Settings `offline_pos_enabled` masih mati.
3. Jalankan seluruh
   `supabase/diagnostics/g4_phase12_offline_sync_preflight.sql`.
4. Kirim semua baris `check_name,status,details`.

## Expected baseline

- seluruh existing-data invariant: `PASS`;
- runtime table/column/routine baru: `SETUP`;
- account function/system event payment exception boleh `SETUP`;
- inventory: `INFO`;
- tidak boleh ada `BLOCKER`.

Endpoint `backoffice/src/app/api/pos/sync/route.ts` harus tetap mengembalikan
`OFFLINE_SYNC_NOT_ENABLED`. Legacy Dexie `saveSaleOffline/syncPendingSales`
belum menjadi canonical contract dan tidak boleh dihubungkan ke endpoint.

## Boundary Phase 12

Phase berikut akan mengutamakan server:

1. menerima envelope dengan stable client transaction/idempotency/hash;
2. mengembalikan replay/status untuk key yang sama;
3. mengunci Submission, Allowance, Stock, dan FIFO;
4. mengonsumsi reservation dan membuat tepat satu Sale final;
5. menyimpan acknowledgement sebelum PWA boleh menghapus local payload;
6. mengarahkan invalid/revoked/stale state ke exception terstruktur.

PWA queue/cache baru boleh dikerjakan setelah atomic server behavior tersebut
lulus. Customer Balance, TEMPO, Ketul, Return, Purchase, dan Adjustment tetap
tidak tersedia offline.

## Recovery

Preflight tidak membutuhkan rollback. Jika ada `BLOCKER`, jangan menulis atau
menjalankan migration sync. Entitlement tetap dimatikan dan endpoint tetap
closed sampai state dikoreksi lewat workflow canonical.

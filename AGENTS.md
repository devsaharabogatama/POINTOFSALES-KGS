# KGS POS Repository Instructions

Semua agent yang bekerja di repository ini wajib membaca dan mengikuti:

1. `docs/AI_AGENT_CONTINUATION_PLAYBOOK.md`;
2. `docs/README.md`;
3. `docs/POS_V1_MVP_REQUIREMENT_INDEX.md`;
4. bagian gate aktif pada `docs/POS_V1_IMPLEMENTATION_GATES.md`;
5. bagian gap dan spesifikasi modul yang relevan dengan task.

Aturan ringkas:

- jangan mengubah approved business flow, memperluas scope, atau membuka deferred module tanpa instruksi user;
- jangan menganggap legacy code sebagai source of truth jika bertentangan dengan spesifikasi terbaru;
- pertahankan compatibility dan perubahan user lain; hindari broad refactor;
- jangan mengubah schema/UI hanya karena requirement sudah disetujui;
- semua tenant, role, feature, stock, pricing, payment, dan Finance invariant harus ditegakkan server-side;
- mutation penting wajib transactional, idempotent, concurrency-safe, dan dapat ditelusuri;
- service-role/secret hanya server-side dan tidak boleh masuk log/dokumen/client;
- perubahan schema memerlukan migration, backfill, verification, dan rollback/forward-fix note;
- setiap task selesai harus menyertakan evidence test, langkah manual, compatibility, serta sisa gap.

File `backoffice/AGENTS.md` tetap berlaku sebagai instruksi tambahan untuk pekerjaan Next.js di dalam folder `backoffice`.

## Handoff Wajib Antar-Agent

- Setiap agent wajib membaca `docs/ACTIVE_DEVELOPMENT_HANDOFF.md` sebelum mulai bekerja.
- Setiap agent yang membuat perubahan wajib memperbarui file tersebut sebelum
  menyerahkan pekerjaan: status terakhir, file yang diubah, evidence test,
  manual gate yang menunggu user, dan next safe step.
- Setiap build yang mengubah status modul, runtime/setup, migration chain,
  compatibility, atau roadmap wajib sekaligus memperbarui root `README.md`.
  Jangan menulis fitur sebagai aktif bila baru tersedia pada schema/local code.
- Jangan menandai fase `COMPLETE` hanya karena file sudah dibuat; cantumkan
  secara terpisah status local verification, manual Supabase rollout, dan smoke
  test user.
- Jika context/limit hampir habis, hentikan pada boundary aman dan tulis handoff
  yang dapat dijalankan agent berikutnya tanpa menebak keputusan bisnis.

## Mandatory Impact-First Change Protocol

Setiap perubahan, termasuk bug fix, wajib mengikuti aturan berikut:

1. Jangan langsung mengubah kode berdasarkan error terakhir.
2. Audit call chain dan migration aktif yang benar-benar digunakan runtime.
3. Sebelum implementasi, tuliskan impact map:
   - modul dan consumer terdampak;
   - tabel/RPC/UI yang berubah;
   - stock, reservation, FIFO, payment, cashier session, Finance, audit;
   - compatibility data lama;
   - concurrency, idempotency, retry, dan rollback.
4. Bedakan:
   - direct impact;
   - downstream impact;
   - risiko regression;
   - kondisi yang belum dapat dibuktikan.
5. Perubahan berisiko tinggi tidak boleh dikerjakan sebelum desain dampaknya jelas.
6. Jangan menggunakan PASS dengan zero runtime rows sebagai bukti behavioral.
7. Setiap migration wajib memiliki:
   - preflight read-only;
   - migration guard;
   - postflight read-only;
   - behavioral test representatif;
   - rollback/forward-fix note;
   - authenticated end-to-end smoke.
8. Test matrix wajib mencakup status sebelum dan sesudah perubahan, termasuk
   open/closed session, pending/verified payment, partial/full dispatch,
   POS/Backoffice, multi-Company, retry, dan stale version.
9. Jika test menemukan error, hentikan patching berlapis. Audit ulang root cause
   dan seluruh downstream consumer.
10. Jangan menyatakan fitur selesai atau aman hanya karena lint/build/postflight
    PASS. Status harus dibedakan menjadi:
    LOCAL READY, DATABASE LIVE, CLIENT DEPLOYED, SMOKE PASS, dan UAT PASS.
11. Jangan mengubah production atau menjalankan deployment tanpa instruksi user.
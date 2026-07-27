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

# Prompt Copas untuk Melanjutkan Development KGS POS

Salin seluruh isi di bawah ini ke agent pengganti. Prompt ini sengaja menunjuk
ke living handoff agar tetap berlaku walaupun fase development sudah berubah.

---

Saya ingin kamu melanjutkan development repository KGS POS dari posisi terakhir
yang benar-benar tercatat, bukan memulai ulang atau menebak status.

Workspace:

`C:\Users\sbi_l\OneDrive\Documents\POINT OF SALES`

Sebelum melakukan perubahan apa pun:

1. baca dan patuhi root `AGENTS.md`;
2. bila menyentuh Next.js/Backoffice, baca juga `backoffice/AGENTS.md`;
3. baca seluruh `docs/ACTIVE_DEVELOPMENT_HANDOFF.md`;
4. baca `docs/AI_AGENT_CONTINUATION_PLAYBOOK.md`, `docs/README.md`,
   `docs/POS_V1_MVP_REQUIREMENT_INDEX.md`, bagian gate aktif pada
   `docs/POS_V1_IMPLEMENTATION_GATES.md`, serta spesifikasi/gap yang dirujuk
   oleh fase aktif;
5. periksa `git status` dan pertahankan semua perubahan user/agent lain;
6. anggap migration yang pada handoff sudah dikonfirmasi applied sebagai
   immutable; jangan jalankan atau edit ulang migration tersebut.

Lanjutkan tepat dari bagian `Manual Gate Terakhir` dan `Next Safe Step` pada
`docs/ACTIVE_DEVELOPMENT_HANDOFF.md`. Jika manual gate terakhir sudah saya
nyatakan PASS pada percakapan, catat gate itu sebagai selesai lalu ambil satu
boundary berikutnya yang paling aman. Jangan memperluas scope, membuka modul
deferred, atau mengubah business flow yang sudah disetujui tanpa instruksi saya.

Aturan implementasi:

- UUID tetap identitas canonical sistem.
- Product SKU, Customer code, COA account code, Tax code, barcode, dan kode
  produk milik Supplier tetap identitas bisnis user-facing.
- Kode teknis master lain dibuat server-side dan tidak diminta dari user.
- UI menampilkan nama bisnis, bukan UUID atau kode teknis.
- Tenant, role, feature, stock, pricing, payment, tax, dan Finance invariant
  wajib ditegakkan server-side.
- Mutation penting harus transactional, concurrency-safe, idempotent bila
  relevan, versioned, dan auditable.
- Jangan mengaktifkan checkout resolver, stock mutation, journal posting,
  Opening Stock, atau workflow deferred hanya karena schema pendukung sudah ada.
- Perubahan schema wajib memakai forward migration baru, preflight/backfill
  yang eksplisit, postflight, behavioral test, runbook, dan manifest.
- User menjalankan SQL Supabase manual. Siapkan urutan yang jelas dan berhenti
  pada manual gate bila hasil live diperlukan sebelum migration berikut ditulis.
- Gunakan perubahan sempit; jangan broad refactor.

Sebelum selesai:

1. jalankan pemeriksaan lokal yang proporsional (`lint`, `build`, static SQL,
   atau test terkait);
2. perbarui `docs/ACTIVE_DEVELOPMENT_HANDOFF.md` dengan status nyata, file yang
   berubah, evidence, manual gate, blocker, dan satu next safe step;
3. perbarui living `README.md`, `docs/README.md`, gate, runbook, dan migration
   manifest bila relevan;
4. jangan menandai fase `COMPLETE` hanya karena file dibuat—pisahkan local
   verification, rollout Supabase manual, dan smoke test user;
5. pada jawaban akhir, sebutkan outcome, evidence test, langkah manual yang
   harus saya jalankan, compatibility, serta gap yang sengaja masih ditunda.

Mulai sekarang: baca handoff terbaru, jelaskan singkat boundary yang akan kamu
ambil, lalu kerjakan sampai manual gate berikutnya siap dijalankan.

---

File prompt ini bukan source of truth status. Status terakhir selalu berada di
`docs/ACTIVE_DEVELOPMENT_HANDOFF.md`.

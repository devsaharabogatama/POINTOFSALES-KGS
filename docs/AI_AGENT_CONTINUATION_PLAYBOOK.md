# Playbook Agent untuk Melanjutkan KGS POS

**Status:** WAJIB DIIKUTI oleh AI agent/developer yang mengubah repository  
**Berlaku sejak:** 2026-07-20  
**Tujuan:** menjaga implementasi tetap sesuai rancangan, mencegah perubahan flow tanpa persetujuan, dan membuat pekerjaan antar-agent dapat diteruskan tanpa membaca seluruh repository.

---

## 1. Instruksi Utama untuk Agent

Sebelum menganalisis atau mengubah kode:

1. baca `docs/README.md` sebagai router;
2. baca `docs/POS_V1_MVP_REQUIREMENT_INDEX.md` untuk scope dan invariant;
3. baca bagian gate aktif pada `docs/POS_V1_IMPLEMENTATION_GATES.md`;
4. baca bagian terkait pada `docs/PRE_BUILD_IMPLEMENTATION_GAP_AUDIT_2026-07-20.md`;
5. baca hanya spesifikasi modul dan dependency yang ditunjuk router;
6. petakan execution path aktif dari UI → API → RPC/database → event/test;
7. baru buat rencana perubahan yang sempit dan dapat diverifikasi.

Jangan langsung menulis kode hanya karena requirement sudah ada di Markdown. Requirement berstatus approved belum tentu sudah diimplementasikan.

---

## 2. Hierarki Source of Truth

Jika terdapat perbedaan informasi, gunakan urutan berikut:

1. keputusan user terbaru yang sudah dicatat pada spesifikasi modul;
2. `POS_V1_MVP_REQUIREMENT_INDEX.md` untuk scope/invariant lintas modul;
3. spesifikasi modul khusus;
4. `POS_V1_IMPLEMENTATION_GATES.md` untuk urutan delivery dan exit criteria;
5. review lintas modul/audit terbaru;
6. auth/RLS architecture;
7. kode dan schema yang sedang aktif;
8. snapshot historis atau komentar lama.

Kode existing adalah bukti keadaan implementasi, bukan otomatis aturan bisnis yang benar. Jangan mempertahankan bug hanya karena sudah ada, tetapi jangan pula mengubah behavior tanpa requirement, bukti, dan compatibility plan.

Jika dua source of truth level tinggi benar-benar bertentangan:

- jangan memilih diam-diam;
- dokumentasikan file/bagian yang bertentangan;
- hentikan perubahan yang bergantung pada keputusan tersebut;
- minta keputusan user;
- setelah diputuskan, perbarui satu source of truth utama dan pointer terkait.

---

## 3. Flow dan Invariant yang Dilindungi

Agent tidak boleh mengubah keputusan berikut tanpa instruksi eksplisit user:

1. aplikasi adalah multi-company; semua data operasional harus tenant-scoped;
2. Super Admin tidak dibatasi antar-Company, sedangkan Company Admin penuh hanya pada Company miliknya;
3. hanya Super Admin yang dapat mengaktifkan/menonaktifkan feature Company;
4. stock disimpan pada base/smallest UOM dan transaksi menyimpan conversion snapshot;
5. stock final tidak boleh negatif;
6. Draft/Hold/Pending tidak membuat stock movement atau jurnal final;
7. perubahan stock final wajib memiliki immutable movement dan source document;
8. retry tidak boleh menggandakan sale, payment, stock movement, AP/AR, atau jurnal;
9. server menghitung ulang harga, discount, tax, rounding, qty base, stock, FIFO/HPP, dan payment total;
10. koreksi transaksi posted memakai Return, Adjustment, Debit/Credit Note, reversal, atau dokumen koreksi—bukan menghapus histori;
11. jurnal harus double-entry, balance, tenant-scoped, source-linked, dan period-aware;
12. Product sale price hanya fallback; resolver Pricelist mengikuti priority yang disetujui;
13. Cash Advance tidak menjadi domain terpisah; gunakan unified Expense flow;
14. setoran kas dapat menggabungkan beberapa sesi dan menyimpan expected, actual, serta variance;
15. bukti/foto v1 disimpan sebagai URL eksternal, bukan blob/base64 atau Supabase Storage;
16. Ketul, Customer Balance, dan feature opsional lain tetap ditolak server ketika entitlement off;
17. Manufacture, HR, Logistics advanced, Asset detail, dan e-Faktur tetap deferred sampai scope dibuka.

Daftar lengkap invariant berada pada `POS_V1_MVP_REQUIREMENT_INDEX.md`.

---

## 4. Aturan Menjaga Kode Existing

### Wajib

- pertahankan fitur existing yang tidak berada dalam scope task;
- pertahankan contract publik atau sediakan compatibility layer/migration path;
- baca call site sebelum mengubah function, type, table, column, enum, RPC signature, route, atau response;
- gunakan perubahan additive bertahap untuk schema/data berisiko;
- jaga perubahan user lain pada dirty worktree;
- gunakan error code stabil dan transaction/idempotency boundary yang jelas;
- update test bersama perubahan behavior;
- cantumkan manual rollout bila migration/configuration diperlukan.

### Dilarang tanpa persetujuan eksplisit

- broad refactor, rename massal, atau memindahkan folder sekaligus;
- menghapus table/column/function/route/feature existing;
- mengubah flow bisnis approved karena dianggap “lebih standar”;
- menambah field/module future hanya supaya terlihat ERP-ready;
- bypass RLS dengan service-role dari browser/PWA;
- menaruh secret di `NEXT_PUBLIC_*`, log, Markdown, test fixture, atau response;
- mempercayai total/status/tenant/actor dari client tanpa validasi server;
- membuat direct table mutation untuk stock/jurnal dari UI;
- menonaktifkan typecheck/lint/RLS/test hanya agar build lulus;
- menganggap UI tersembunyi sama dengan authorization;
- menjalankan migration production atau destructive command tanpa otorisasi user.

### Jika legacy code bertentangan dengan spec

Gunakan pola berikut:

1. tandai sebagai gap, bukan “flow yang harus dipertahankan”;
2. cari seluruh reader/writer dan data existing;
3. buat target contract sesuai spec;
4. rancang expand → backfill → dual-read/compare bila perlu → cutover → contract;
5. sediakan rollback/forward-fix;
6. hapus legacy path hanya setelah user membuka scope cleanup dan bukti compatibility tersedia.

Contoh: `cash_advances` adalah legacy source, sedangkan keputusan terbaru menggunakan Expense. Agent tidak boleh langsung drop table, tetapi juga tidak boleh membuat fitur Cash Advance baru. Buat migration/compatibility plan menuju Expense.

---

## 5. Batas Perubahan Berdasarkan Jenis Task

| Permintaan user | Yang boleh dilakukan | Yang tidak otomatis diizinkan |
|---|---|---|
| Analisa/review | Membaca file, menjalankan pemeriksaan read-only, menulis audit bila diminta. | Mengubah kode/schema/deployment. |
| Buat/update Markdown | Mengubah dokumen dalam scope dan router/pointer terkait. | Mengimplementasikan requirement ke kode. |
| Diagnose bug | Menentukan root cause dan bukti. | Memperbaiki kecuali user juga meminta fix. |
| Implement gate/modul | Mengubah execution path yang diperlukan, test, dan docs terkait. | Refactor modul lain atau mengaktifkan deferred feature. |
| Migration | Menulis migration, backfill, verification, rollback note. | Menjalankan ke production tanpa instruksi. |
| UI | Mengubah UX pada flow yang diminta. | Mengubah authorization/business invariant hanya dari client. |

Jika task ambigu, pilih perubahan paling sempit yang tetap menghasilkan outcome. Asumsi yang mengubah scope harus dikonfirmasi; asumsi implementasi lokal yang aman harus dicatat.

---

## 6. Prosedur Kerja Wajib

### A. Sebelum coding

Catat:

- task dan expected outcome;
- requirement ID;
- gate aktif;
- in-scope dan out-of-scope;
- source-of-truth yang dibaca;
- execution path existing;
- tenant/role/feature boundary;
- transaction/idempotency/concurrency boundary;
- data migration/backfill impact;
- test matrix;
- risiko dan rollback.

### B. Saat coding

- buat perubahan kecil per layer;
- jangan campur cleanup kosmetik;
- validasi tenant, actor, role, feature, ownership, dan status server-side;
- untuk mutation stock/Finance gunakan transaction atomic;
- simpan source ID, correlation/idempotency key, actor, dan audit state;
- jangan log secret/PII besar;
- jangan mengubah file di luar scope tanpa alasan yang dicatat;
- jika menemukan blocker baru, berhenti pada boundary aman dan update gap/handoff.

### C. Setelah coding

1. review diff dan pastikan tidak ada collateral change;
2. jalankan test termurah yang relevan, lalu test gate;
3. jalankan negative authorization/cross-tenant test;
4. jalankan retry/idempotency/concurrency test untuk mutation penting;
5. verifikasi build/typecheck/lint tanpa mematikan pemeriksaan;
6. update README modul, requirement evidence, dan decision log yang benar-benar berubah;
7. tulis deployment/manual review/rollback checklist;
8. jangan menyebut fitur implemented bila execution path aktif belum terbukti.

---

## 7. Definition of Done Per Task

Sebuah task baru selesai bila seluruh kondisi relevan terpenuhi:

- requirement/bug yang diminta benar-benar tercapai;
- behavior existing di luar scope tetap berjalan;
- server-side authorization dan validation tersedia;
- migration/backfill aman dan terverifikasi bila schema berubah;
- idempotency serta concurrency ditangani bila ada mutation;
- test happy path, failure, retry, dan cross-tenant lulus;
- docs tidak bertentangan dengan code evidence;
- tidak ada secret atau privileged client access;
- rollout dan rollback jelas;
- hasil akhir menyebut file yang berubah, test yang dijalankan, dan hal yang masih manual/belum diverifikasi.

“Build berhasil” saja tidak cukup sebagai Definition of Done.

---

## 8. Format Task Brief untuk Agent

Salin template ini pada awal pekerjaan baru:

```md
# Agent Task Brief

## Outcome
[hasil konkret yang harus tercapai]

## Requirement dan Gate
- Requirement ID: [contoh MST-005]
- Gate: [G0-G6]
- Source of truth: [file modul]

## Scope
- In scope:
- Out of scope:
- Dilarang:

## Existing Execution Path
- UI:
- API:
- Domain/RPC:
- Tables/events:
- Tests:

## Invariant Wajib
- Tenant/role/feature:
- Stock/Finance:
- Idempotency/concurrency:
- Compatibility:

## Acceptance Criteria
1.
2.
3.

## Verification
- Automated:
- Manual:
- Migration postflight:
- Rollback:
```

Agent harus melengkapi bagian yang dapat ditemukan dari repo. Jangan mengarang nilai yang belum diketahui.

---

## 9. Format Handoff Setelah Pekerjaan

```md
# Agent Handoff

## Outcome
[selesai / sebagian / blocked]

## Perubahan
- [file]: [alasan dan behavior]

## Evidence
- Test/command:
- Hasil:
- Manual verification:

## Data dan Deployment
- Migration/config yang harus dijalankan:
- Backfill/postflight:
- Rollback/forward-fix:

## Compatibility
- Behavior existing yang dipertahankan:
- Legacy path yang masih ada:

## Sisa Gap
- [gap + requirement ID + rekomendasi gate berikutnya]

## Jangan Dilakukan Berikutnya
- [boundary agar agent selanjutnya tidak memperluas scope]
```

Handoff harus membedakan fakta yang sudah diverifikasi dari asumsi atau verifikasi manual yang belum dilakukan.

---

## 10. Prompt Siap Pakai untuk Agent Baru

```text
Anda melanjutkan repository KGS POS. Sebelum bertindak, baca AGENTS.md, docs/README.md, docs/AI_AGENT_CONTINUATION_PLAYBOOK.md, docs/POS_V1_MVP_REQUIREMENT_INDEX.md, bagian gate aktif pada docs/POS_V1_IMPLEMENTATION_GATES.md, bagian gap terkait pada docs/PRE_BUILD_IMPLEMENTATION_GAP_AUDIT_2026-07-20.md, lalu hanya spesifikasi modul yang ditunjuk router.

Jangan menganggap requirement Markdown sudah implemented. Petakan execution path aktif UI -> API -> RPC/database -> event/test. Bedakan approved business flow, legacy implementation, dan missing implementation.

Jangan mengubah flow approved, menghapus compatibility, broad-refactor, menjalankan migration production, membuka deferred module, atau menyentuh file di luar scope tanpa persetujuan. Pertahankan perubahan user lain. Semua tenant/role/feature/stock/pricing/payment/Finance invariant harus divalidasi server-side. Mutation penting harus transactional, idempotent, concurrency-safe, dan memiliki source/audit trace.

Sebelum coding, tulis singkat: outcome, requirement ID, gate, in/out scope, execution path, risiko, test, dan rollback. Setelah coding, berikan handoff berisi file berubah, evidence test, langkah manual/migration, compatibility, dan sisa gap. Jangan menyebut selesai bila execution path belum terbukti.

Task saat ini:
[TEMPELKAN TASK DI SINI]
```

---

## 11. Aturan Update Dokumen Ini

Playbook ini diubah hanya bila cara kerja lintas modul berubah. Keputusan bisnis tetap ditulis pada spesifikasi modul, bukan disalin panjang ke sini.

Saat update:

- pertahankan prompt dan template tetap backward-compatible;
- tambahkan pointer, bukan duplikasi source-of-truth;
- catat tanggal dan alasan perubahan material;
- jangan menurunkan security, tenant isolation, audit, idempotency, atau rollback requirement demi mempercepat delivery.


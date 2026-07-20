# G1 Fase 1 Rollout Evidence — 2026-07-20

**Migration:** `20260720090000_g1_phase1_security_feature_foundation.sql`  
**Evidence source:** output manual Supabase SQL Editor yang diberikan user  
**Status:** COMPLETE — MIGRATION, POSTFLIGHT, BEHAVIORAL TEST, DAN APP SMOKE PASS

## Postflight

Seluruh 17 check lulus:

- tidak ada privilege table `anon` pada schema public;
- `authenticated` tidak memiliki `TRUNCATE`, `REFERENCES`, atau `TRIGGER`;
- enam feature catalog seed tersedia dan tidak ada feature yang aktif;
- ledger migration memiliki tepat satu row versi `20260720090000`;
- tiga feature table ada dan RLS aktif;
- delapan `company_id` target sudah `NOT NULL`;
- authenticated tidak dapat menjalankan worker Finance atau transfer legacy.

## Behavioral Test Pertama

Test berhenti dengan:

```text
TEST_PRECONDITION_FAILED: one Super Admin, one normal user, and one Company are required
```

Error tersebut berasal dari precondition test versi awal dan belum membuktikan kegagalan authorization. Test awal menggabungkan tiga dependency dalam satu pesan sehingga objek yang tidak tersedia tidak dapat dibedakan.

Perbaikan test:

- normal actor sekarang memakai UUID non-Super-Admin yang tidak perlu dibuat sebagai user production;
- bila belum ada Company, test membuat fixture di dalam transaction yang selalu `ROLLBACK`;
- satu-satunya dependency data yang wajib adalah Profile Super Admin yang masih terhubung ke `auth.users`;
- diagnostic `supabase/diagnostics/g1_phase1_behavior_preflight.sql` ditambahkan untuk memberi count tanpa menampilkan identitas/PII.

## Behavioral Preflight dan Retest

Behavior preflight terbaru menghasilkan:

| Check | Status | Count |
|---|---|---:|
| Company | PASS | 1 |
| Normal Profile | PASS / informational | 0 |
| Super Admin Profile | PASS | 1 |
| Super Admin Profile linked to Auth | PASS | 1 |

Behavioral test versi terbaru kemudian selesai sukses. Hal ini membuktikan dalam transaction test bahwa:

- actor non-Super-Admin tidak dapat mengubah entitlement;
- Super Admin dapat mengubah entitlement untuk target Company eksplisit;
- guard membaca feature enabled dengan benar;
- tepat satu audit mutation tercatat;
- seluruh perubahan test dibatalkan oleh `ROLLBACK`.

Tidak adanya Normal Profile bukan blocker test maupun migration. Namun user non-Super-Admin tetap diperlukan nanti untuk UAT role matrix lengkap G1.

## App Smoke Test

User mengonfirmasi frontend existing aman setelah migration:

- login Super Admin berhasil;
- frontend tetap menampilkan behavior lama sebagaimana expected;
- tidak ada regression yang dilaporkan pada flow existing.

Tidak adanya fitur UI baru adalah expected karena G1 fase 1 hanya membangun fondasi database/security. G1 fase 1 ditutup dan G1 fase 2 dapat dimulai.

Sebelum UAT matrix role G1 penuh, tetap perlu dibuat minimal satu user non-Super-Admin.

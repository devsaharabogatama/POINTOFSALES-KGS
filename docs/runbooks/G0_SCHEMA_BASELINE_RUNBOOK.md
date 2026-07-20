# Runbook Manual G0 — Schema Baseline Supabase

**Status:** baseline selesai; menunggu catalog fingerprint  
**Risiko:** read-only terhadap persistent database; memakai TEMP table session-local  
**Script:** `../../supabase/diagnostics/g0_schema_baseline.sql`  
**Tujuan:** membuktikan keadaan schema live sebelum migration G1 ditulis.

---

## 1. Yang Tidak Dilakukan pada G0

- tidak menjalankan `schema.sql` atau migration existing;
- tidak mengubah password/user/role;
- tidak mengubah policy/grant/function;
- tidak memasukkan seed;
- tidak memperbaiki row error langsung;
- tidak membagikan API key, service-role key, password, atau isi `.env.local`.

Script diagnostic membuat TEMP table pada schema session `pg_temp`. Supabase SQL Editor dapat melakukan commit boundary antar-statement, sehingga script sengaja tidak memakai `ON COMMIT DROP`. TEMP table hilang otomatis ketika database session SQL Editor selesai. Hasil yang dikembalikan hanya metadata dan hitungan, bukan isi row bisnis.

---

## 2. Persiapan Manual

1. Buka Supabase Dashboard project yang dipakai Backoffice/POS.
2. Pastikan nama project dan project ref pada URL dashboard sesuai dengan host `NEXT_PUBLIC_SUPABASE_URL` di local environment. Cukup cocokkan project ref; jangan kirim nilai key.
3. Pastikan branch yang dipilih adalah branch yang memang ingin diaudit. Jika production, jangan menjalankan query selain diagnostic G0.
4. Buka **SQL Editor → New query**.
5. Salin seluruh isi `supabase/diagnostics/g0_schema_baseline.sql`.

---

## 3. Menjalankan Diagnostic

1. Jalankan seluruh file sekaligus, mulai komentar paling atas sampai query `SELECT` terakhir.
2. Pastikan query selesai tanpa error.
3. Result terakhir harus memiliki kolom:

```text
section | check_name | status | details
```

4. Download/export result sebagai CSV jika tersedia, atau salin seluruh result.
5. Berikan hasilnya kepada Codex/agent berikutnya. Result ini tidak seharusnya mengandung email, password, token, atau data transaksi individual.

Jika query error:

- jangan menghapus bagian script dan menjalankan sisanya secara acak;
- salin pesan error lengkap beserta nomor baris;
- jangan mencoba migration/fix;
- kembalikan error tersebut agar script disesuaikan berdasarkan bukti live.

---

## 4. Cara Membaca Status

| Status | Arti | Tindakan |
|---|---|---|
| `FAIL` | Invariant/data/security check gagal. | Blocker; harus dianalisis sebelum G1. |
| `MISSING` | Object/column/function yang diharapkan tidak ditemukan. | Tentukan apakah belum applied atau memang superseded. |
| `WARN` | Object ada tetapi posture belum aman/final. | Review grant, nullability, search path, atau public execute. |
| `SKIP` | Check tidak dapat/relevan dijalankan karena dependency tidak ada. | Selesaikan dependency mapping. |
| `PASS` | Check minimum lolos. | Bukan bukti seluruh behavior benar; lanjutkan test gate. |
| `INFO` | Metadata/inventory. | Dipakai mencocokkan manifest. |

Prioritas review:

1. tenant mismatch atau `company_id` NULL;
2. negative product stock;
3. unbalanced journal group;
4. RLS disabled/no policy;
5. function public execute atau SECURITY DEFINER tanpa fixed search path;
6. migration registry/object mismatch.

---

## 5. Evidence yang Dikembalikan

Kirimkan:

- hasil CSV/table dari diagnostic;
- nama branch yang diaudit: production/staging/local;
- konfirmasi apakah query selesai dan result final tampil;
- error lengkap jika gagal.

Jangan kirim:

- `.env.local`;
- publishable/anon/service-role/secret key;
- password;
- raw customer/sales/payment rows.

---

## 6. Langkah Setelah Hasil Diterima

Agent berikutnya akan:

1. membandingkan live object dengan `supabase/MIGRATION_MANIFEST.md`;
2. menandai migration/script mana yang terbukti applied;
3. membuat applied-state report tanpa mengubah production;
4. menetapkan nomor forward migration pertama untuk G1;
5. menyusun migration + backfill + RLS test G1;
6. meminta persetujuan manual lagi sebelum migration dijalankan.

G1 tidak dimulai dengan asumsi. Hasil diagnostic G0 adalah input wajib.

---

## 7. Follow-Up Fingerprint Setelah Baseline

Baseline 2026-07-20 selesai tanpa `FAIL`, tetapi migration registry tidak tersedia. Untuk menentukan exact applied-state:

1. buka **SQL Editor → New query** pada project/branch yang sama;
2. copy seluruh `supabase/diagnostics/g0_schema_fingerprint.sql`;
3. jalankan sekali;
4. export result `object_type | object_name | property | value` sebagai CSV/text;
5. kirim hasil ke agent;
6. jangan menjalankan migration/legacy script apa pun.

Fingerprint bersifat `SELECT`-only dan tidak memakai TEMP table.

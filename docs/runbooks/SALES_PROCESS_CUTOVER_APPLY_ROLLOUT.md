# Sales Process Cutover Apply — Step 1E/6

Status: converter dua arah dan Retail session adoption sudah
`DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS` pada isolated
Development. Step 4E atomic Apply sekarang `LOCAL READY`; migration Apply,
client, authenticated smoke, dan UAT belum dijalankan.

## Tujuan gate saat ini

Gate ini hanya mengaudit data dan kontrak aktual sebelum converter atomik
ditulis. Ia membuktikan mapping dua arah tanpa membuat target, membatalkan
source, memindahkan Reservation, mengganti mode Company, atau menulis audit.

Keputusan yang sudah final:

- source baru ditutup `CANCELED` setelah target lengkap berhasil dibuat;
- source log menampilkan nomor dan link target dari lineage canonical;
- pending Revision, open procurement/PO, serta Office non-TEMPO bertanggal
  mendatang menjadi `BLOCKED` dan tetap grandfathered;
- item `BLOCKED`/`KEEP_SOURCE` tidak menggagalkan switch;
- Apply hanya manual oleh Platform Super Admin pada/setelah `effective_at`;
- seluruh conversion, classification ulang, mode history, dan mode switch harus
  commit atau rollback sebagai satu transaksi.

## Impact map

Direct impact tahap Apply berikutnya:

- `sales_process_cutover_plans/items/audit`;
- `company_sales_process_settings` dan immutable mode history;
- source/target `sales_headers` + lines atau `backoffice_sales_orders` + lines;
- Reservation source/target untuk dokumen yang sudah confirmed/reserved;
- activity lineage source menuju nomor target.

Downstream yang tidak boleh mendapat final effect dari conversion:

- Stock Movement, FIFO dan On Hand;
- SJ/DO yang sudah mulai dikirim;
- Payment dan cashier drawer/session;
- Finance Event, posting queue dan Journal;
- procurement demand/PO;
- Invoice yang sudah mempunyai Payment/Finance effect.

Risiko regression yang diuji: duplicate target saat retry, stale plan/settings/
source version, source canceled tanpa target, reservation terhitung ganda,
cross-Company mapping, UUID mentah pada log, dan conversion data yang tidak
memiliki line/UOM canonical.

## Langkah manual sekarang — isolated Development saja

1. Pastikan project Supabase yang aktif adalah Development
   `fkywtxucmyjvpwdiqpix`, bukan production/staging.
2. Jalankan seluruh file
   `supabase/diagnostics/sales_process_cutover_apply_preflight.sql`.
   File tersebut sengaja hanya mempunyai satu result query agar SQL Editor
   menampilkan seluruh check dalam satu tabel.
3. Pastikan hasil memuat marker `preflight_revision` dengan revision
   `STEP_1E_V2_ONE_RESULT`. Jika marker tidak ada, SQL lama/selection parsial
   yang berjalan dan hasilnya tidak boleh dipakai.
4. Kirim seluruh result set, termasuk baris `SETUP` dan `INFO`.
5. Stop jika ada `BLOCKER` atau SQL error.
6. Jangan membuat/menghapus plan secara manual dan jangan mengubah data agar
   hasil terlihat PASS.

`SETUP` pada classifier open procurement, future non-TEMPO, empty document,
line/UOM, atau Reservation berarti data tersebut harus diklasifikasikan
fail-closed oleh migration berikutnya. `SETUP` bukan kegagalan preflight dan
bukan izin membuat mapping palsu.

## Setelah output diterima

Migration Step 1E akan ditulis berdasarkan result aktual, lalu disertai:

- migration guard dan classifier upgrade;
- postflight SELECT-only;
- behavioral rollback dengan fixture yang dibentuk dari header/preparation yang
  sama dengan runtime canonical;
- exact retry, stale version, multi-Company, partial failure rollback, dan
  zero Stock/Payment/Finance effect assertions;
- rollback/forward-fix note dan authenticated smoke matrix.

Apply belum boleh digunakan hanya karena preflight ini selesai.

## Step 1E-A - classifier fail-closed

Preflight V2 dikonfirmasi user: seluruh dependency/shape `PASS`, runtime tidak
memiliki candidate atau plan, dan satu kondisi expected `SETUP` membuktikan
open procurement masih diklasifikasikan sebagai conversion requirement.

Urutan manual berikutnya pada isolated Development:

1. jalankan
   `supabase/diagnostics/sales_process_cutover_procurement_blocker_preflight.sql`;
2. stop bila ada `BLOCKER`; baris legacy classifier harus `SETUP`;
3. jalankan migration
   `supabase/migrations/20260910140000_sales_process_cutover_procurement_blocker.sql`;
4. jalankan behavioral rollback
   `supabase/tests/sales_process_cutover_procurement_blocker_behavior.sql`;
5. jalankan postflight
   `supabase/diagnostics/sales_process_cutover_procurement_blocker_postflight.sql`;
6. kirim seluruh hasil. Stop bila ada SQL error atau `FAIL`.

Migration ini hanya mengubah pure classifier: source nonfinal dengan open
procurement/PO menjadi `BLOCKED` memakai kode stabil
`OPEN_PROCUREMENT_MUST_FINISH`. Pending Revision, blocker dispatch/Stock/
Payment/Finance, final `KEEP_SOURCE`, dan clean `CONVERT` diuji tetap sama.
Tidak ada conversion, perubahan mode, maupun mutation data operasional.

Setelah Step 1E-A PASS, Step 1E-B baru membangun converter atomik, retirement
source, lineage target, Reservation transfer, audit, dan mode switch.

User telah mengonfirmasi migration, behavioral test, dan postflight Step 1E-A
seluruhnya PASS. Converter Step 1E-B berhenti sebelum implementasi sampai
otoritas nilai komersial target diputuskan eksplisit: preserve snapshot source
atau repricing memakai resolver target.

## Rollback / forward-fix Step 1E-A

- SQL error sebelum `COMMIT` merollback penggantian function dan ledger secara
  atomik.
- Setelah commit, jangan menghapus ledger atau mengubah function manual. Jika
  kontrak bermasalah, gunakan forward migration yang memulihkan definisi
  classifier terverifikasi.
- Karena gate ini tidak menulis plan/dokumen/Reservation/Stock/Finance, tidak
  ada backfill atau pemulihan data operasional.
- Authenticated smoke Super Admin terhadap preview baru tetap manual dan baru
  dinyatakan PASS setelah output user tersedia.

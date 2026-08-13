# G6 Corrective Phase 7B — Human IDs, Ledger, dan Excel Export

## Status

`DATABASE USER VERIFIED; AUTHENTICATED UI SMOKE PENDING`

Forward fix ini merupakan perubahan rundown yang disetujui user setelah
workspace Finance awal dapat dibuka. Scope-nya terbatas pada identitas manusia
dan presentation/read/export; tidak membuka event posting baru.

## Hasil yang dituju

- UUID/FK/idempotency key tetap menjadi identitas backend dan tidak diubah;
- jurnal memakai `JUR/YYYY/MM/######`, reversal `JRB/...`, posting queue
  `PST/...`, exception `EXC/...`, dan reconciliation `REC/...`;
- nomor dialokasikan server-side, unik per Company/prefix/bulan, dan aman pada
  request bersamaan;
- Buku Besar menampilkan seluruh akun, lalu detail transaksi secara expandable;
- Journal Entries menampilkan dokumen jurnal dan debit/kredit ketika dibuka;
- ekspor bulanan menghasilkan file XLSX nyata, bukan CSV berganti ekstensi.

## Urutan manual wajib

Jalankan satu per satu di Supabase SQL Editor:

1. `supabase/diagnostics/g6_phase7b_finance_human_identifiers_preflight.sql`
2. `supabase/migrations/20260811100000_g6_phase7b_finance_human_identifiers.sql`
3. `supabase/diagnostics/g6_phase7b_finance_human_identifiers_postflight.sql`
4. `supabase/tests/g6_phase7b_finance_human_identifiers_tests.sql`

Expected:

- preflight dependency dan browser boundary `PASS`; `BACKFILL` nomor legacy
  adalah expected;
- migration committed satu kali;
- seluruh postflight non-INFO `PASS`;
- behavioral test mengeluarkan `TEST PASSED` lalu seluruh fixture rollback.

Setelah database lulus, restart Backoffice agar route yang memilih `display_no`
memakai schema cache terbaru.

## Smoke UI

1. Buka **Finance > Operasi Finance > Buku Besar**.
2. Ganti bulan, cari akun, aktifkan filter akun nol, dan expand minimal satu
   akun yang bergerak.
3. Klik nomor jurnal pada detail; halaman harus berpindah ke Journal Entries
   dan membuka bulan/hasil pencarian yang sesuai.
4. Pastikan UUID, `G6-<uuid>`, `REV-<uuid>`, `FQ-...`, dan event UUID tidak
   tampil sebagai label user.
5. Export Buku Besar dan Journal Entries; buka file pada Excel/LibreOffice dan
   periksa summary, detail, metadata Company/timezone/filter/report version.
6. Ganti active Company dan ulangi; data maupun nomor Company lain tidak boleh
   terlihat.

## Compatibility dan forward-fix note

- kolom identity lama (`id`, `journal_no`, `queue_no`) tidak dihapus atau
  ditulis ulang; referensi historis tetap valid;
- `reconciliation_no` memang business number, sehingga existing value
  dinormalisasi satu kali ke `REC/...` tanpa mengubah UUID dokumen;
- trigger immutable/audit reconciliation hanya dinonaktifkan di dalam transaksi
  migration untuk backfill nomor, lalu diaktifkan kembali sebelum commit;
- Finance posting engine, FIFO, AP/AR, Payment, Inventory, POS, dan PWA tidak
  berubah;
- rollback produksi setelah migration bukan drop column. Bila ada masalah,
  gunakan forward fix dan pertahankan nomor yang sudah dialokasikan.

## Evidence lokal

- scoped ESLint: PASS;
- Next production build: PASS, termasuk route
  `/api/finance/operations/export`;
- XLSX ZIP/XML smoke: PASS;
- authenticated Supabase rollout/smoke: menunggu user.

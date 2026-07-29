# G3 Phase 10 — Stock Opname Preflight

## Status

`READY FOR MANUAL PREFLIGHT`

Jalankan seluruh:

`supabase/diagnostics/g3_phase10_stock_opname_preflight.sql`

Diagnostic ini hanya `SELECT` dan tidak membuat sesi, saldo, FIFO, Movement,
Adjustment, event Finance, user assignment, atau perubahan privilege.

## Output yang diharapkan

### Harus PASS

- dependency canonical Stock Adjustment;
- tenant/reference integrity legacy Opname;
- arithmetic legacy `physical - system`;
- tidak ada duplicate Product dalam satu sesi;
- approved legacy line sudah memiliki Adjustment atau memang zero variance;
- linkage Opname–Adjustment valid dan tidak ganda;
- balance sama dengan total immutable Movement;
- positive balance sama dengan remaining FIFO;
- seluruh Product stok aktif memiliki Base UOM canonical;
- Movement final memiliki timestamp, Base UOM, dan balance snapshot untuk
  movement watermark;
- setiap Company aktif memiliki alasan `Selisih Stok` yang aktif dan dapat
  dipakai untuk gain/loss;
- RPC canonical Adjustment tersedia.

### REVIEW/BACKFILL yang harus dikirim lengkap

- `overlapping_nonfinal_legacy_product_count`: perlu aturan supersede eksplisit
  bila ada sesi legacy overlap;
- `approved_legacy_line_without_adjustment`: perlu backfill Adjustment/linkage
  sebelum schema cutover.

Jangan lanjut migration bila salah satunya nonzero.

### INFO yang expected

- inventory sesi/detail legacy;
- channel Store/POS/Gudang/Cashier yang tersedia;
- enum legacy biasanya hanya `DRAFT`, `SUBMITTED`, `APPROVED`;
- kolom canonical blind-count/recount/supersede, count-attempt/audit table, dan
  RPC Opname biasanya belum ada;
- direct browser write harus seluruhnya `false`.

## Boundary desain setelah preflight bersih

Target migration berikut wajib mempertahankan:

- satu sesi untuk satu Company dan satu Gudang;
- scope `ALL`, `CATEGORY`, atau `SELECTED`;
- kasir membuat/menghitung dari POS tanpa melihat system qty, expected qty,
  variance, HPP, atau nilai;
- status sesi `DRAFT → COUNTING → COMPLETED → POSTED/CANCELED`;
- status line `PENDING`, `COUNTED`, `RECOUNT_REQUIRED`, `SUPERSEDED`, `POSTED`;
- expected quantity dihitung dari snapshot awal ditambah Movement sampai
  `counted_at`;
- movement di tengah window count memicu recount tanpa membekukan penjualan;
- hitungan terbaru dapat supersede line lama per Product–Gudang;
- Store Manager hanya mereview/post pada Store/Gudang assignment;
- Company Owner/Admin dan Super Admin dapat review/post dalam Company scope;
- Finance read-only dan bukan approval wajib;
- posting memakai canonical Adjustment secara atomic dan menyimpan counted time
  terpisah dari accounting/posting time;
- retry/idempotency tidak boleh menggandakan Adjustment atau Movement.

## Jika hasil tidak sesuai

Hentikan pada preflight. Kirim seluruh baris hasil dan error lengkap. Jangan
mengedit migration Phase 8 yang sudah applied dan jangan membuat direct write
ke tabel legacy.

# G3 Phase 4 — Stock Movement / Kartu Stok Preflight

## Status

`READY FOR MANUAL PREFLIGHT`

## Tujuan

Audit SELECT-only sebelum memperluas ledger existing menjadi kontrak Kartu Stok
canonical. Existing row Opening Stock tidak boleh dirusak atau ditulis ulang
tanpa backfill eksplisit.

File:

`supabase/diagnostics/g3_phase4_stock_movement_preflight.sql`

## Cara menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file preflight.
3. Kirim semua baris `check_name,status,details`.
4. Jangan membuat migration Kartu Stok sebelum seluruh `BLOCKER` bersih.

## Expected current result

- dependency, shape, tenant reference, duplicate source, balance reconciliation,
  Base UOM, dan Opening Stock coverage: `PASS`;
- schema state: `INFO` dengan kolom audit canonical yang masih missing;
- enum state: `INFO` dengan movement type future yang masih missing;
- inventory: satu atau lebih movement Opening Stock sesuai data smoke;
- direct browser write: seluruhnya `false`.

## Mengapa UI belum langsung dibuat

Roadmap mensyaratkan Kartu Stok menampilkan actor, source line, status, Base UOM
snapshot, notes, dan saldo setelah movement. Schema existing hanya menyimpan
Product, Gudang, perubahan quantity, movement type, source header, dan waktu.
Menampilkan field audit palsu atau menebak actor dari UI dilarang.

Hasil preflight menentukan:

- kolom additive dan backfill yang aman;
- enum yang benar-benar perlu dibuka pada fase ini;
- immutable/source uniqueness guard;
- cara menyimpan `balance_after_base_qty` secara atomic bersama balance update;
- API/UI read-only setelah ledger canonical lulus postflight dan behavior.

## Boundary

- tidak membuka Transfer, Sale, Return, Opname, atau Adjustment posting;
- tidak membuka G4 notification/Stock Request;
- tidak membuka G5 Purchasing;
- tidak memberi browser write privilege ke `stock_movements`;
- tidak menghitung ulang dan menulis saldo existing pada preflight.

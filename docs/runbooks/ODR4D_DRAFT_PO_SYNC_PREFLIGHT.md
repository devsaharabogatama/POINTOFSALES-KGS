# ODR-4D — Preflight Sinkronisasi Draft PO

## Tujuan

Mengaudit apakah quantity demand/Stock Request terkelola dapat disinkronkan ke
Draft PO tanpa mengubah PO final atau quantity manual Purchasing.

File ini SELECT-only:

`supabase/diagnostics/odr_phase4d_draft_po_sync_preflight.sql`

## Interpretasi

- `BLOCKER`: hentikan; kirim seluruh output.
- `PASS`: invariant live aman.
- `REVIEW`: inventaris keputusan runtime, bukan otomatis kegagalan.
- `SETUP`: runtime ODR-4D memang belum dipasang.
- `INFO`: jumlah request/order/allocation live.

Aturan yang tidak boleh berubah:

1. hanya PO `DRAFT` yang boleh disinkronkan;
2. PO `CONFIRMED`, `PARTIALLY_RECEIVED`, atau `RECEIVED` tidak diubah;
3. kenaikan quantity hanya dapat masuk otomatis bila target Draft PO tunggal
   dan allocation-backed;
4. target ambigu, quantity manual campuran, atau PO final menghasilkan delta /
   amendment notice untuk Purchasing;
5. preflight dan fase runtime tidak membuat Stock, FIFO, Movement, AP, event,
   atau jurnal.

## Langkah

1. Jalankan preflight satu kali di Supabase SQL Editor.
2. Kirim seluruh hasil ke agent.
3. Jangan menjalankan migration ODR-4D sebelum seluruh `BLOCKER` dinilai.

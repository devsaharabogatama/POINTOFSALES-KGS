# Purchase Daily Replenishment Step 6/6A — Supplier Assignment AP Bridge

Status paket: **LOCAL READY**. Target hanya Supabase Development terisolasi
`fkywtxucmyjvpwdiqpix`. Production dan staging tidak boleh disentuh.

## Outcome

- Assignment Supplier pada Receipt `SUPPLIER_PENDING` membuat satu AP
  Provisional canonical per Receipt line dari nilai clearing yang sama.
- Receipt posted, Stock, FIFO, dan Movement tidak ditulis ulang.
- Event Receipt supplier-pending masuk Antrian Jurnal lebih dahulu dan
  membentuk Dr `INVENTORY_ASSET` / Cr `PURCHASE_UNASSIGNED_CLEARING`.
- Event assignment masuk Antrian Jurnal existing dan membentuk Dr
  `PURCHASE_UNASSIGNED_CLEARING` / Cr `SUPPLIER_AP_PROVISIONAL` per Supplier.
- Event bernilai nol ditutup `CANCELED / NO_FINANCIAL_EFFECT` tanpa jurnal nol.
- AP Provisional hasil assignment otomatis terlihat oleh workspace `Faktur
  Supplier` existing. Paket tidak membuat Supplier Bill atau Payment otomatis.
- Supplier Invoice yang memakai AP hasil assignment belum masuk queue sebelum
  jurnal assignment posted, sehingga urutan clearing → AP Provisional → AP Final
  tidak dapat terbalik.
- Queue dan posting core sama-sama menolak event assignment sebelum event
  Receipt asal berstatus final (`POSTED`, atau `CANCELED` khusus nilai nol).

## Urutan manual

Jalankan file penuh, bukan selected text:

1. [Preflight](../../supabase/diagnostics/purchase_supplier_assignment_ap_bridge_preflight.sql)
2. [Migration](../../supabase/migrations/20260914130000_purchase_supplier_assignment_ap_bridge.sql)
3. [Behavioral test](../../supabase/tests/purchase_supplier_assignment_ap_bridge_behavior.sql)
4. [Postflight](../../supabase/diagnostics/purchase_supplier_assignment_ap_bridge_postflight.sql)

Hentikan bila preflight mengeluarkan `BLOCKER` atau SQL error. Behavioral wajib
berakhir dengan `TEST_PASS`; seluruh fixture berada dalam `BEGIN/ROLLBACK`.
Postflight hanya boleh berisi `PASS/INFO`.

## Impact dan compatibility

- Direct: assignment wrapper, AP provisional lifecycle guard, posting Receipt
  supplier-pending, posting assignment, generic event support, dan Purchase/AP
  preview.
- Downstream: Supplier Invoice matching existing memperoleh source AP yang sah;
  Supplier Payment tetap hanya membaca Invoice `VALIDATED`.
- Tidak berubah: generator AUTO_RO/AUTO_PO, PO manual, Receipt assigned lama,
  Stock/FIFO/Movement, POS Retail, template Invoice, role/capability, dan data
  production.
- Existing assignment yang exact dibackfill menjadi AP Provisional; conflict
  Supplier/nilai/source menjadi blocker dan tidak ditebak.

## Forward-fix

Migration applied tidak boleh diedit atau dihapus. Jika rollout gagal setelah
commit, pertahankan mode Purchase `MANUAL`, jangan proses event assignment, dan
buat migration maju baru. Tidak ada rollback yang menghapus AP/history/jurnal.

## Sisa Step 6

Setelah database behavior dan postflight user-confirmed PASS: authenticated
smoke assignment → Antrian Jurnal → Faktur Supplier → Pembayaran Supplier,
kemudian scheduler 23:59 dan UI Purchase Daily/UAT sebagai paket terpisah.

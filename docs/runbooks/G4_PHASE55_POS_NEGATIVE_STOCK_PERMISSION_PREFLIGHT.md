# G4 Phase 55 — POS Negative Stock Permission Preflight

## Scope yang dibuka user

User meminta izin stock minus di POS dimasukkan ke rundown bersama Customer
Balance. Ini merupakan perubahan terhadap invariant lama `final stock tidak
boleh negatif`, sehingga fitur tetap default OFF dan tidak boleh dibuat sebagai
toggle kosmetik client.

Phase 55 hanya audit SELECT-only. Tidak ada stock, FIFO, Warehouse, Sale, atau
permission yang diubah.

## Target contract awal

- hanya online; Offline Stock Allowance tidak boleh minus;
- Company feature default OFF dan hanya Super Admin yang dapat membukanya;
- Warehouse sale-source harus opt-in;
- Cashier membutuhkan permission eksplisit dan setiap penggunaan menyimpan
  actor, alasan, requested/available/negative qty, serta source Sale;
- Bundle tidak boleh memakai jalur minus pada fase awal;
- server tetap menghitung quantity base, mengunci Sale/Stock, dan menjaga retry
  menghasilkan satu final effect;
- negative quantity memerlukan allocation/cost basis provisional yang dapat
  direkonsiliasi ketika stock masuk—tidak boleh mengarang FIFO layer normal;
- browser tidak memperoleh direct write Stock/FIFO/Movement/Warehouse.

## Jalankan

Jalankan seluruh:

`supabase/diagnostics/g4_phase55_pos_negative_stock_permission_preflight.sql`

Kirim seluruh output. `SETUP` pada schema, Warehouse hard-false guard, dan Sale
shortage runtime adalah expected. `BLOCKER` harus nol. `REVIEW` pada cost basis
menentukan desain provisional HPP/replenishment phase berikutnya.

## Boundary roadmap

Customer Balance foundation tetap track terpisah agar ledger liability tidak
tercampur dengan exception inventory. Kedua track harus lulus regression
bersama sebelum consolidated G4 end-to-end UAT.

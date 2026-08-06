# G4 Phase 14 — Offline Catalog Cache Preflight

## Outcome

Memastikan snapshot cache offline dapat berasal dari server-authoritative
Product-UOM, Pricelist, Tax, Payment, Terminal policy, dan allowance. Phase ini
belum membuat migration dan belum membuka checkout offline.

## Urutan

1. Pastikan entitlement `offline_pos_enabled` tetap disabled.
2. Jalankan seluruh file
   `supabase/diagnostics/g4_phase14_offline_catalog_cache_preflight.sql`.
3. Kirim seluruh output, termasuk baris `INFO` dan `SETUP`.

## Interpretasi

- `BLOCKER`: hentikan; jangan aktifkan offline.
- `REVIEW`: ada submission nonterminal yang harus direkonsiliasi.
- `SETUP` pada snapshot RPC: expected sebelum foundation Phase-14.
- `SETUP` pada Terminal policy: Terminal belum dipilih sebagai offline-enabled;
  ini configuration gate, bukan alasan mengaktifkan feature sekarang.
- `INFO` Pricelist/Tax menentukan bentuk snapshot server yang wajib dibuat;
  client tidak boleh menebak resolver.

## Boundary

- tidak ada DDL/DML atau side effect;
- retained queue Phase-13 belum menerima payload Keranjang;
- endpoint legacy `/api/pos/sync` tetap closed;
- Customer Balance, Ketul, TEMPO fisik, Return, Expense, Goods Receipt,
  Adjustment, dan Stock Opname tetap tidak tersedia offline.

## Next Safe Step

Jika tidak ada `BLOCKER`, buat guarded catalog snapshot RPC dan cache lokal yang
menyimpan resolved price/Tax/Payment serta allowance per Session/Terminal.
Entitlement baru boleh diaktifkan pada UAT terpisah setelah hash dan local
allowance reconciliation lulus.

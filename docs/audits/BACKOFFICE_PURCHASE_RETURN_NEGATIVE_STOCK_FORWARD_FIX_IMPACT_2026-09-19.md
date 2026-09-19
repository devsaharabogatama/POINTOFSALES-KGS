# Backoffice Supplier Return Negative-Stock Forward Fix — Impact Audit

**Status:** LOCAL READY; Production belum dijalankan.  
**Migration:** `20260919143000_backoffice_purchase_return_negative_stock_runtime.sql`

## Root cause

Flow awal membatasi quantity Retur Supplier dengan `product_batches.qty_remaining`
dan `product_stocks.stock_qty`. Pada bisnis KGS, Goods Receipt dapat langsung
terserap untuk menutup On Hand negatif. Akibatnya exact batch Receipt menjadi
nol walaupun quantity komersial Receipt tersebut belum pernah diretur. Ini
menyebabkan blocker `PURCHASE_RETURN_FIFO_NOT_AVAILABLE` yang tidak sesuai
dengan proses bisnis.

## Kontrak yang disetujui

- hak retur dibatasi exact quantity Posted Goods Receipt dikurangi Retur Posted;
- Retur tetap memakai PO/GR/batch dan biaya historis sumber yang sama;
- Retur tidak boleh mengambil quantity dari batch lain;
- On Hand boleh kembali negatif hanya pada Warehouse yang telah mengaktifkan
  otorisasi stok minus;
- shortage akibat source FIFO habis dicatat terpisah dan ditutup oleh Goods
  Receipt berikutnya;
- selisih biaya Receipt berikutnya terhadap biaya historis retur masuk
  `PURCHASE_PRICE_VARIANCE` (PPV), bukan COGS;
- Retail/PWA Purchase Return, transaksi Posted, Bill, Payment, Supplier Credit,
  dan histori lama tidak ditulis ulang.

## Impact map

Direct impact:

- read model workspace Retur Supplier Backoffice;
- Save Draft dan Post Retur Supplier Backoffice;
- Stock Movement `PURCHASE_RETURN` saat balance menjadi negatif;
- rekonsiliasi batch baru terhadap shortage Retur;
- dua baris jurnal koreksi Inventory/PPV pada Goods Receipt berikutnya bila
  biaya aktual berbeda.

Downstream impact:

- AUTO RO tetap membaca On Hand negatif yang dihasilkan Retur;
- Goods Receipt berikutnya mengurangi shortage dan batch available secara
  atomic;
- jurnal Goods Receipt tetap seimbang dan inventory yang sudah habis secara
  fisik tidak menyisakan nilai akibat cost difference.

Tidak berubah:

- jalur POS/PWA Purchase Return dan Cashier Session;
- urutan `UNINVOICED_FIRST`, AP Final, Supplier Refund Receivable;
- Supplier Payment net guard dan PO cancellation gate;
- Stock/FIFO batch lain, Sales, Customer Return, Customer Receipt.

## Concurrency, retry, dan compatibility

- Post tetap memakai advisory lock Product/Warehouse, row lock allocation,
  batch, stock, dan idempotency key existing.
- shortage mempunyai unique key per Return line; retry Posted tetap masuk jalur
  idempotent sebelum membuat effect baru.
- replenishment diproses FIFO berdasarkan waktu shortage dan dikunci `FOR UPDATE`.
- runtime POS dan Backoffice negative-stock reconciliation lama dipertahankan;
  shortage Retur diproses setelah keduanya tanpa mengganti data lama.

## Risiko dan pembuktian

- Mapping `INVENTORY_ASSET` dan `PURCHASE_PRICE_VARIANCE` wajib tersedia.
- Warehouse sumber wajib aktif dan telah mengizinkan stok minus.
- PASS dengan nol row bukan bukti behavior; behavioral test membuat sendiri
  Receipt yang FIFO-nya dibuat nol, melakukan dua Retur, membentuk Stock -10,
  lalu memasukkan Receipt biaya berbeda dan membuktikan shortage/PPV/jurnal.
- Runtime PostgreSQL Production tetap harus melalui preflight, migration,
  rollback-only behavior, postflight, dan authenticated smoke.

## Rollback / forward-fix

Migration atomic: error sebelum `COMMIT` membatalkan seluruh file. Setelah ada
shortage atau Return Posted baru, object tidak boleh di-drop dan ledger tidak
boleh dihapus. Koreksi berikutnya wajib additive forward-fix dan transaksi
bisnis harus dibalik memakai dokumen source-linked, bukan edit histori.

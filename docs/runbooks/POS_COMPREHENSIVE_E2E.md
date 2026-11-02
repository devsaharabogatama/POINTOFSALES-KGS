# POS comprehensive local E2E

## Tujuan dan batas bukti

Runner ini membangun source PWA terkini lalu menjalankan browser E2E dengan
fixture terisolasi serta pemeriksaan wiring runtime. Runner tidak menulis ke
Production dan tidak menggantikan authenticated smoke atau UAT.

Status yang boleh disimpulkan:

- browser case hijau: `MOCKED E2E PASS` untuk flow dan payload yang diuji;
- runtime contract hijau: `RUNTIME CONTRACT PASS` untuk wiring source;
- seluruh suite hijau tidak berarti `DATABASE LIVE`, `SMOKE PASS`, atau
  `UAT PASS`.

## Prasyarat

- Node/npm tersedia;
- dependency `qa-e2e` sudah terpasang;
- Google Chrome tersedia di
  `C:/Program Files/Google/Chrome/Application/chrome.exe`.

Tidak ada instalasi tool tambahan yang diperlukan pada workstation saat ini.

## Menjalankan seluruh POS gate

Dari root repository:

```powershell
npm.cmd --prefix qa-e2e run test:pos
```

Runner akan:

1. menjalankan production build `pwa`;
2. membuka/reuse preview lokal `http://127.0.0.1:5197`;
3. menjalankan browser suite `retail-pwa.mocked.spec.ts`;
4. menjalankan `runtime-contract.spec.ts`;
5. membuat HTML report, screenshot, dan trace untuk failure.

## Membuka report

```powershell
npm.cmd --prefix qa-e2e run report:pos
```

File report:

`qa-e2e/playwright-report/pos/index.html`

Trace failure dapat dibuka dengan command yang dicetak Playwright, misalnya:

```powershell
npx.cmd --prefix qa-e2e playwright show-trace qa-e2e/test-results/pos/<test>/trace.zip
```

## Cakupan browser saat ini

- direct Retail Pickup: receipt dan Invoice tanpa Order reservation/SJ;
- Catalog/Cart geometry serta footer Total Akhir;
- Ketul ready dan fail-closed;
- Return field Cash/Transfer;
- direct POS Expense;
- Session Summary dan Return shortcut;
- Quick Customer dengan field opsional kosong;
- buka dan tutup Cashier Session;
- Delivery Draft dan ongkir;
- Sales Return approval Draft;
- split Cash + QRIS;
- Tempo Draft;
- Stock Request;
- Goods Receipt;
- Supplier Return Draft;
- blind Stock Opname;
- Cash Deposit;
- canonical runtime separation POS/Backoffice dan wiring operational RPC.

Setiap mutasi mocked yang lulus memeriksa RPC dan material payload, bukan hanya
keberadaan tombol.

## Baseline 2026-11-01 dan hasil fix 2026-11-02

- PWA build: PASS (peringatan chunk-size lama tetap ada);
- total: 27;
- baseline awal: 26 PASS, 1 FAIL;
- penyebab baseline: Delivery Draft tidak dapat menekan `Simpan pengiriman`
  karena sticky `.pos-action-bar` dari checkout menghalangi pointer pada tombol
  dialog;
- setelah fix layering yang diaudit: 27 PASS, 0 FAIL;
- Delivery Draft sekarang membuktikan normal pointer click, payload penerima,
  alamat, jadwal, ongkir, catatan, dan tidak melakukan final post.

Fix tidak menggunakan `force: true` dan tidak melemahkan assertion bisnis.
Status hijau ini hanya untuk mocked browser/source-contract runner; gap database
nyata di bawah tetap terbuka.

## Gap yang belum dibuktikan oleh runner ini

- authenticated database smoke dan downstream Stock/FIFO/Finance/Journal;
- Draft reopen/cancel dan revisi Order lengkap;
- offline queue lifecycle lengkap;
- seluruh negative permission, cross-Company, duplicate, stale-version,
  concurrency, dan rollback terhadap database nyata;
- seluruh cabang partial/full dispatch Backoffice;
- Expense settlement lanjutan;
- Opname create/start/recount/cancel.

Gap tersebut harus diberi test tersendiri sebelum ada klaim E2E keseluruhan
lintas database dan Finance.


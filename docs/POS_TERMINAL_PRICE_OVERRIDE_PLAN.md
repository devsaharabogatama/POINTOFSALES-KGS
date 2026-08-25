# POS Terminal Price Override Plan

Status: **STAGING DEPLOYED; AUTHENTICATED TRANSACTION SMOKE PENDING**
Keputusan user: 25 Agustus 2026

## Tujuan

Setiap Terminal/POS dapat dikonfigurasi untuk mengizinkan atau melarang kasir
mengubah harga jual per baris transaksi. Kebijakan melekat pada Terminal, bukan
pada identitas atau role kasir. Jika Terminal mengizinkan, semua kasir yang sah
pada Terminal tersebut memperoleh fungsi yang sama.

## Urutan harga

1. POS tetap menampilkan harga canonical seperti sekarang: Customer Pricelist,
   Global Pricelist/tier, lalu harga fallback Product-UOM.
2. Tidak ada perubahan perilaku bila kasir tidak mengisi harga override.
3. Jika kasir sengaja mengisi harga override pada suatu baris, harga tersebut
   menjadi harga jual authoritative untuk baris itu dan mengalahkan seluruh
   Pricelist yang sebelumnya ter-resolve.
4. Diskon line/transaksi, pajak, pembulatan, pembayaran, stok, FIFO, HPP, serta
   Finance tetap dihitung oleh canonical server core setelah harga override.
5. Override tidak mengubah Master Product-UOM maupun Pricelist dan tidak
   memengaruhi transaksi lain.

## Kebijakan Terminal

- Default Terminal: override harga **OFF**.
- Pengaturan ditempatkan bersama pengaturan Terminal POS, tetapi berbeda dari
  `hidden_feature_keys`: ini adalah izin transaksi server-side, bukan sekadar
  penyembunyian UI.
- Pengelola mengikuti authority Terminal UI existing: Super Admin, Company
  Owner/Admin, dan Store Manager hanya pada Store yang menjadi scope-nya.
- Mengaktifkan/menonaktifkan kebijakan wajib versioned dan audited.
- Perubahan kebijakan berlaku pada Save/Post berikutnya. Draft lama tidak boleh
  lolos dengan harga override jika Terminal sudah menonaktifkannya.

## Kontrak server dan audit

- Browser tidak boleh menjadikan field harga sebagai sumber kebenaran tanpa
  pengecekan ulang Terminal, Store, Session, Product-UOM, dan Company.
- Save Draft dan Post wajib menolak override bila Terminal tidak mengizinkan.
- Setiap line yang dioverride menyimpan harga dasar Product-UOM, Pricelist/rule
  yang semula ter-resolve, harga hasil Pricelist, harga override final, actor,
  Terminal, Session, alasan/source, dan waktu resolve.
- Exact retry harus menghasilkan satu final effect dan snapshot yang sama.
- Retur, Invoice, laporan penjualan, dan jurnal menggunakan harga final yang
  benar-benar diposting; histori Pricelist tetap dapat ditelusuri.
- Harga negatif dilarang. Keputusan batas minimum/maksimum belum dibuka; sampai
  ada keputusan lain, implementasi tidak boleh menambahkan batas persen atau
  approval per kasir yang tidak diminta user.

## UX yang disetujui

- Saat izin OFF, kontrol ubah harga tidak tampil dan API/RPC tetap menolak
  payload override.
- Saat izin ON, kasir dapat mengubah harga per line di cart.
- Tampilan awal selalu harga Pricelist canonical.
- Line yang diubah diberi label jelas **Harga diubah**, menampilkan harga
  Pricelist semula dan harga final, serta menyediakan aksi **Kembalikan ke harga
  Pricelist**.
- Pergantian Customer, Pricelist, UOM, atau quantity menghitung ulang harga
  canonical. Override eksplisit tidak boleh hilang diam-diam; UI harus meminta
  konfirmasi jika perubahan konteks akan mengganti atau membatalkannya.

## Batas scope awal

- Hanya checkout POS online.
- Offline tetap memakai snapshot canonical dan tidak menerima price override
  sampai kontrak cache, sync, konflik, dan audit Offline disetujui terpisah.
- Tidak mengubah hak akses Pricelist Backoffice.
- Tidak mengubah fitur diskon yang sudah ada.

## Rencana implementasi

1. **Preflight:** inventaris Terminal policy, Sale line snapshot, resolver,
   Draft/Post wrappers, Return/Invoice/Finance consumer, dan Offline boundary.
2. **Foundation:** policy per Terminal, version/audit, snapshot line additive,
   guarded resolver contract, postflight, dan rollback-safe behavior.
3. **Online runtime:** Save/Post authoritative validation, idempotency,
   Pricelist/discount/tax/rounding/Finance compatibility, dan regression.
4. **PWA UX:** kontrol edit/reset harga, visual snapshot, Draft restore, dan
   protection terhadap perubahan Customer/Pricelist/UOM/quantity.
5. **Closure:** authenticated two-Terminal UAT (ON versus OFF), direct API/RPC
   denial, retry/concurrency, Return/Invoice/journal reconciliation, build, dan
   deployment smoke.

Migration `20260825120000`, postflight awal, dan behavior rollback-safe telah
dikonfirmasi PASS oleh user.
Pengaturan Terminal Backoffice dan cart PWA Online sudah local-ready. Urutan
closing dan smoke ada di `docs/runbooks/POS_TERMINAL_PRICE_OVERRIDE_ROLLOUT.md`.
Closing postflight staging sudah PASS dan kedua client staging telah dideploy.
Status operasional belum ditutup sebelum authenticated ON/OFF transaction,
Offline denial, retry, dan reconciliation smoke selesai.

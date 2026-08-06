# G4 Phase 22 — POS End-to-End UAT

## Tujuan dan Batas

Checklist ini menutup gate manual POS yang tersedia sampai Phase 22: Online
checkout, Draft, Split Payment, Offline allowance, warm-session Offline
checkout, retained queue, sync, dan invoice final.

Transaksi yang berhasil di-Post atau disinkronkan adalah transaksi nyata:
Stock, FIFO, Payment, Financial Event, dan nomor invoice akan terbentuk. Gunakan
Company, Toko, Terminal, Gudang, Customer, Product, dan Kasir uji.

Belum menjadi kriteria lulus Phase 22:

- membuka PWA dari kondisi mati total ketika perangkat sudah Offline;
- Bundle Offline, TEMPO Offline, Customer Balance, Return, Expense, atau Deposit;
- membiarkan konflik mengganti data server secara diam-diam.

Cold-start Offline dan controlled conflict/recovery adalah gate setelah seluruh
tes di dokumen ini lulus.

## Data Uji Minimum

Siapkan:

- satu Company uji aktif;
- satu Toko, Terminal POS, Gudang sumber jual, dan Kasir aktif;
- satu Cashier Session `OPEN`;
- satu Customer reguler dengan default Pricelist dan Customer `Walk-In`;
- satu Product stok non-Bundle dengan Base UOM, Sales UOM, harga, FIFO, dan stok
  cukup;
- sedikitnya dua Payment Method aktif, salah satunya Cash;
- entitlement Offline aktif hanya pada Company uji;
- policy Company dan Terminal Offline aktif;
- allowance Product diterbitkan untuk Session dan stoknya masih mencukupi.

Catat sebelum tes: Stock aktual, sisa FIFO, sisa allowance, saldo sesi, dan
jumlah Sale/Payment/Movement. Gunakan nilai transaksi yang mudah direkonsiliasi.

## A. Login, Scope, dan Session

| ID | Aksi | Expected |
|---|---|---|
| E2E-01 | Login dengan akun tanpa assignment Kasir aktif | Terminal tidak dapat dipilih dan transaksi tidak dapat dibuka |
| E2E-02 | Login dengan Kasir yang benar | Hanya Company/Toko/Terminal/Gudang yang menjadi scope user yang tampil |
| E2E-03 | Buka sesi dengan kas awal | Session menjadi `OPEN`; scope Terminal dan Gudang terkunci pada sesi |
| E2E-04 | Refresh PWA setelah sesi terbuka | Session dan scope yang sama pulih tanpa membuat sesi kedua |

## B. Checkout Online Dasar

| ID | Aksi | Expected |
|---|---|---|
| E2E-05 | Tambah Product, ubah quantity, lalu hapus satu baris | Total dan Cart konsisten; tombol/icon tidak overlap |
| E2E-06 | Pilih Customer dengan default Pricelist | Pricelist Customer otomatis terpilih dan harga server sesuai |
| E2E-07 | Override ke Pricelist lain yang eligible | Harga berubah sesuai resolver server; Customer tidak berubah |
| E2E-08 | Buat Customer cepat dari POS | Customer hanya masuk ke active Company dan langsung dapat dipilih |
| E2E-09 | Gunakan satu metode Cash | Bagian tagihan otomatis sama dengan total final; tepat satu Sale `POSTED`, Payment, Stock Movement, FIFO allocation, Financial Event, dan receipt terbentuk |
| E2E-10 | Buka receipt | Terbuka di tab baru, dapat dicetak, dan memakai snapshot transaksi |
| E2E-11 | Kembali ke POS setelah sukses | Cart, Payment, Customer override, dan input transaksi kembali ke keadaan awal |

## C. Harga, Payment, dan Retry Online

| ID | Aksi | Expected |
|---|---|---|
| E2E-12 | Split Payment dengan dua metode hingga total tepat | Kedua bagian tersimpan satu kali; jumlah dasar pembayaran sama dengan grand total |
| E2E-13 | Masukkan jumlah split kurang/lebih atau metode duplikat | Post ditolak dengan pesan jelas; tidak ada efek final |
| E2E-14 | Isi `Uang diterima` Cash lebih besar dari bagian tagihan | Post berhasil, kembalian benar, dan nilai Sale tidak berubah; Customer Balance tidak dibuat |
| E2E-15 | Klik/retry Post berulang pada request yang sama | Hanya satu Sale dan satu rangkaian efek Stock/Payment/Event |
| E2E-16 | Coba quantity di atas stok | Ditolak server; Stock, FIFO, Payment, Event, dan Sale final tidak berubah |

## D. Draft dan Lock

| ID | Aksi | Expected |
|---|---|---|
| E2E-17 | Simpan Cart sebagai Draft | Draft muncul; tidak ada Payment final, Movement, FIFO consumption, atau Event |
| E2E-18 | Buka Draft dari Kasir lain di Toko yang sama | Visibility sesuai scope; lock mencegah dua editor aktif |
| E2E-19 | Resume Draft setelah harga berubah | Harga di-resolve ulang dan Payment wajib dikonfirmasi ulang |
| E2E-20 | Cancel Draft memakai modal aplikasi | Draft canceled dan audit terbentuk; dialog bawaan browser tidak muncul |
| E2E-21 | Tekan `Escape` pada modal/drawer | Lapisan teratas tertutup tanpa mengubah data |

## E. Persiapan Offline

| ID | Aksi | Expected |
|---|---|---|
| E2E-22 | Online: buka Session dan menu Offline | Snapshot dicoba otomatis; setelah meminta allowance Product, snapshot valid menunjukkan scope, Product, Payment, Pricelist, dan allowance |
| E2E-23 | Bandingkan allowance server dan lokal | Sisa lokal tidak melebihi server dan quantity memakai Base UOM |
| E2E-24 | Nonaktifkan entitlement/policy pada scope uji | Snapshot/allowance/checkout Offline ditolak; aktifkan kembali sesudahnya |

## F. Warm-Session Offline Happy Path

Jangan tutup atau reload aplikasi setelah memutus koneksi. Phase 22 hanya
mendukung aplikasi yang sudah aktif dan sudah memiliki snapshot.

| ID | Aksi | Expected |
|---|---|---|
| E2E-25 | Setelah snapshot siap, putuskan koneksi | Status berubah Offline dan Product eligible tersedia dari snapshot |
| E2E-26 | Pilih Customer/Pricelist, Product non-Bundle, quantity di bawah allowance, dan Cash exact | Harga bertanda sumber snapshot dan total konsisten |
| E2E-27 | Tekan `Simpan Offline` dan konfirmasi | Cart reset; satu record `PENDING SYNC`; allowance lokal berkurang satu kali |
| E2E-28 | Buka Slip Offline | Ada watermark `BELUM TERSINKRON — BUKAN INVOICE FINAL`; bukan nomor invoice server |
| E2E-29 | Buka/tutup menu Offline dan modal dengan tombol serta `Escape` | Queue tetap ada tanpa kehilangan record |

## G. Negative Path Offline

Seluruh kasus berikut harus ditolak sebelum local commit:

| ID | Kasus | Expected |
|---|---|---|
| E2E-30 | Quantity melebihi allowance | Ditolak; queue dan allowance lokal tidak berubah |
| E2E-31 | Product Bundle | Ditolak untuk Offline |
| E2E-32 | Payment TEMPO/Customer Balance/tidak ada di snapshot | Ditolak untuk Offline |
| E2E-33 | Product, UOM, Payment, Customer, Pricelist, atau scope missing/stale | Fail closed; tidak ada queue baru |
| E2E-34 | Total Payment tidak exact | Ditolak; tidak ada local commit |

## H. Reconnect, Sync, dan Recovery

| ID | Aksi | Expected |
|---|---|---|
| E2E-35 | Sambungkan koneksi, lalu tekan `Sinkronkan` | Status terkontrol sampai `POSTED` atau exception eksplisit |
| E2E-36 | Tekan retry/status check berulang pada record yang sama | Tetap satu submission, Sale, Payment set, Stock effect, dan Event |
| E2E-37 | Buka invoice final dari queue `POSTED` | Invoice memakai receipt snapshot server dan berbeda jelas dari Slip Offline |
| E2E-38 | Refresh aplikasi setelah record diakui server | Acknowledgement retained tetap terlacak; transaksi tidak dikirim ulang |
| E2E-39 | Putuskan koneksi saat submit/process, lalu reconnect dan retry | Record tidak hilang; status server diperiksa; tidak ada efek ganda |
| E2E-40 | Tutup Session saat ada submission nonterminal/allowance aktif | Close ditolak sampai queue selesai dan allowance dirilis |

## I. Rekonsiliasi Akhir

Sesudah semua transaksi:

1. Stock aktual turun sesuai total Base UOM yang benar-benar `POSTED`;
2. FIFO tersisa sama dengan Stock aktual;
3. Kartu Stok menunjukkan sumber Sale Offline dan snapshot saldo;
4. jumlah Payment dasar sama dengan grand total setiap Sale;
5. satu transaksi memiliki satu Financial Event;
6. allowance `consumed` sama dengan ledger consumption;
7. tidak ada submission `QUEUED`, `SYNCING`, `NEEDS_CONFIRMATION`, atau `FAILED`;
8. direct browser write ke Sale, Stock, FIFO, Movement, Payment, dan allowance
   tetap tertutup.

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g4_phase12_offline_sync_postflight.sql
supabase/diagnostics/g4_phase21_offline_checkout_queue_preflight.sql
```

Expected:

- Phase 12 hanya `PASS`/`INFO`;
- Phase 21 tidak memiliki `BLOCKER`;
- `offline_checkout_uat_scope` menjadi `PASS`, bukan `SETUP`;
- `posted_offline_submissions` minimal `1`;
- `nonterminal_offline_submission` bernilai `0`;
- rekonsiliasi Stock–Movement dan Stock–FIFO bernilai `0`;
- duplicate submission identity bernilai `0`.

## Evidence yang Dikirim

Kirim hasil lengkap kedua SQL diagnostic, screenshot Slip Offline dan invoice
final untuk transaksi yang sama, screenshot queue sebelum/sesudah sync, hasil
Stock aktual/Kartu Stok, serta ID tes yang gagal dan pesan persisnya.

Jangan kirim password, access token, service-role key, atau payload sensitif.

## Cleanup dan Next Gate

Release/revoke allowance tersisa, tutup Session, dan nonaktifkan
entitlement/policy Offline pada Company uji bila tidak sedang dipilotkan.

Jika seluruh checklist lulus, next roadmap adalah cold-start retained restore
dan controlled conflict/recovery stress. Jika ada kegagalan, perbaiki Phase 22
lebih dulu; jangan membuka modul deferred.

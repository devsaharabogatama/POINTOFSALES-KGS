# Company Branding Logo Specification

**Status:** BRD-1 DATABASE PASS; BRD-2 UPLOAD/UI LOCAL READY  
**Scope:** logo Company untuk template dokumen; bukan evidence transaksi

## Tujuan dan Access

Company dapat memasang satu logo aktif untuk Sales Invoice, Surat Jalan, dan
template resmi berikutnya. Logo opsional; dokumen tanpa logo tetap valid.

- upload/replace/remove: Super Admin atau membership aktif Owner/Admin;
- role lain hanya membaca resolved branding sesuai akses Company;
- direct browser write ke metadata dan `storage.objects` dilarang;
- server memvalidasi session, active Company, role, dan file bytes;
- public URL hanya untuk baca logo pada dokumen eksternal; write tetap server.

## File Contract

- PNG, JPEG, atau WebP; maksimum 2 MiB (2,097,152 byte);
- SVG, GIF, PDF, base64, dan format lain ditolak;
- MIME wajib cocok magic bytes; nama/extension browser bukan authority;
- path server-owned: `{company_id}/logo/v{version}-{checksum_prefix}.{ext}`;
- checksum SHA-256 dihitung server;
- bucket `company-branding`, public read, tanpa direct authenticated write.

## Metadata dan Audit

`company_branding_profiles` menyimpan `company_id`, object path, public URL,
MIME, size, SHA-256, logo/master version, actor, dan timestamp.
`company_branding_audit` menyimpan `UPLOAD`, `REPLACE`, atau `REMOVE` beserta
actor dan before/after metadata; tidak menyimpan file bytes.

## Replace, Remove, dan Snapshot

- replace membuat path/version baru agar cache lama tidak tertukar;
- metadata dikomit setelah upload berhasil; kegagalan metadata memicu cleanup
  object baru secara best effort;
- object lama dihapus setelah metadata baru aktif; kegagalan cleanup dicatat;
- remove mengosongkan logo aktif dan template memakai fallback;
- dokumen final menyimpan branding snapshot/version. Logo baru tidak mengubah
  histori dokumen lama.

## Non-Goals

- bukti transfer, foto produk, dan attachment tetap external-link;
- tidak ada custom theme, crop/editor, gallery, atau cross-Company shared logo;
- tidak ada file bytes di PostgreSQL atau filesystem Vercel.

## Verification Minimum

- upload/replace/remove dan fallback;
- wrong MIME, spoofed extension, SVG, oversize, dan empty file;
- stale version, exact retry, concurrent replace;
- role allow/deny, active Company mismatch, cross-tenant path;
- direct table/storage mutation denial, audit, cache-busting, cleanup, snapshot.

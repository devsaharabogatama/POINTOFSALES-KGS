type ErrorMessages = Readonly<Record<string, string>>

const commonMessages: ErrorMessages = {
  AUTHENTICATION_REQUIRED: 'Sesi login tidak ditemukan. Login kembali, lalu ulangi tindakan ini.',
  INVALID_SESSION: 'Sesi login sudah tidak berlaku. Login kembali, lalu ulangi tindakan ini.',
  ACTIVE_COMPANY_NOT_FOUND: 'Company aktif belum dipilih. Pilih Company dari header, lalu coba kembali.',
  COMPANY_ACCESS_DENIED: 'Akun ini tidak mempunyai akses ke Company aktif. Minta Admin Company memeriksa keanggotaan Anda.',
  CUSTOM_PERMISSION_DENIED: 'Hak akses akun ini tidak mengizinkan tindakan tersebut. Minta Admin Company memeriksa permission role Anda.',
  FORBIDDEN: 'Akun ini tidak diizinkan melakukan tindakan tersebut. Periksa role dan permission pada Company aktif.',
  SUPER_ADMIN_REQUIRED: 'Tindakan ini hanya dapat dilakukan oleh Super Admin.',
  MASTER_VERSION_CONFLICT: 'Data sudah berubah sejak halaman dibuka. Muat ulang, periksa perubahan terbaru, lalu coba kembali.',
  IDEMPOTENCY_PAYLOAD_CONFLICT: 'Permintaan dengan identitas yang sama pernah dikirim dengan isi berbeda. Muat ulang lalu kirim ulang dari form terbaru.',
  ACTIVE_FINANCE_POSTING_QUEUE_EXISTS: 'Masih ada antrean posting Finance aktif. Selesaikan atau batalkan antrean tersebut sebelum melanjutkan.',
  ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS: 'Antrean posting Finance aktif sudah tersedia. Buka antrean yang ada; jangan membuat antrean kedua.',
  ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS: 'Mapping akun Finance belum ada atau lebih dari satu. Admin Finance harus memperbaiki mapping akun sebelum transaksi dapat diposting.',
  POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND: 'Tidak ada periode Finance terbuka untuk tanggal transaksi ini. Buka periode yang sesuai atau gunakan tanggal pada periode terbuka.',
  OPEN_ACCOUNTING_PERIOD_REQUIRED: 'Tanggal transaksi harus berada pada periode Finance yang terbuka.',
  NONTERMINAL_OFFLINE_SUBMISSION_EXISTS: 'Masih ada transaksi offline yang belum selesai diproses. Selesaikan sinkronisasi tersebut sebelum melanjutkan.',
  SUPABASE_NOT_CONFIGURED: 'Koneksi database aplikasi belum dikonfigurasi. Hubungi administrator deployment.',
  SUPABASE_ADMIN_NOT_CONFIGURED: 'Konfigurasi server untuk operasi administratif belum tersedia. Hubungi administrator deployment.',
}

function errorCode(value?: string | null) {
  if (!value?.trim()) return ''
  const normalized = value.trim()
  const knownShape = normalized.match(/[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+/)
  return knownShape?.[0] ?? normalized
}

function genericMessage(code: string) {
  if (code.endsWith('_REQUIRED')) {
    return `Data wajib belum lengkap (${code}). Lengkapi field atau konfigurasi yang diminta, lalu coba kembali.`
  }
  if (code.endsWith('_NOT_FOUND')) {
    return `Data atau konfigurasi yang dibutuhkan tidak ditemukan (${code}). Muat ulang; jika tetap terjadi, minta admin memeriksa data master terkait.`
  }
  if (code.endsWith('_INVALID')) {
    return `Data yang dikirim tidak valid (${code}). Periksa nilai pada form, lalu coba kembali.`
  }
  if (code.endsWith('_IMMUTABLE')) {
    return `Dokumen sudah final dan tidak boleh diubah langsung (${code}). Gunakan proses koreksi resmi yang tersedia.`
  }
  if (code.endsWith('_CONFLICT')) {
    return `Data bertabrakan dengan perubahan terbaru (${code}). Muat ulang dan periksa dokumen sebelum mencoba kembali.`
  }
  if (code.endsWith('_FAILED') || code.endsWith('_OPERATION_FAILED')) {
    return `Operasi belum berhasil (${code}). Muat ulang dan coba sekali lagi; jika tetap gagal, laporkan kode ini kepada administrator.`
  }
  return `Tindakan belum dapat dilanjutkan (${code}). Muat ulang dan periksa data; jika tetap terjadi, laporkan kode ini kepada administrator.`
}

export function userFacingError(
  value?: string | null,
  moduleMessages: ErrorMessages = {},
  emptyFallback = 'Operasi belum berhasil.',
) {
  const code = errorCode(value)
  if (!code) return emptyFallback

  const moduleKey = Object.keys(moduleMessages).find((key) => code.includes(key))
  if (moduleKey) return moduleMessages[moduleKey]

  const commonKey = Object.keys(commonMessages).find((key) => code.includes(key))
  if (commonKey) return commonMessages[commonKey]

  return genericMessage(code)
}

import { createClient } from '@supabase/supabase-js'

const supabaseUrl = (import.meta.env.VITE_SUPABASE_URL || '').trim()
const supabaseAnonKey = (import.meta.env.VITE_SUPABASE_ANON_KEY || '').trim()

function hasValidUrl(value: string) {
  try {
    const parsed = new URL(value)
    return (
      ['http:', 'https:'].includes(parsed.protocol) &&
      !parsed.hostname.includes('your-project')
    )
  } catch {
    return false
  }
}

function hasValidPublicKey(value: string) {
  const normalized = value.toLowerCase()
  return (
    value.length >= 20 &&
    !normalized.includes('your-anon') &&
    !normalized.includes('placeholder')
  )
}

export const supabaseConfigurationError =
  !hasValidUrl(supabaseUrl) || !hasValidPublicKey(supabaseAnonKey)
    ? 'Konfigurasi Supabase PWA belum valid. Isi VITE_SUPABASE_URL dan VITE_SUPABASE_ANON_KEY, lalu restart PWA.'
    : null

export const supabase = createClient(
  supabaseConfigurationError ? 'http://127.0.0.1:54321' : supabaseUrl,
  supabaseConfigurationError ? 'configuration-not-available' : supabaseAnonKey,
)

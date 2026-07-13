import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL || ''
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY || ''

if (!supabaseUrl || !supabaseAnonKey) {
  console.warn('Warning: Supabase credentials are not fully configured in your .env file.')
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey)

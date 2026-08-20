import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

function isConfigured(value: string | undefined) {
  if (!value) return false
  const normalized = value.trim().toLowerCase()
  return (
    normalized.length > 0 &&
    !normalized.includes('your-project') &&
    !normalized.includes('your-anon') &&
    !normalized.includes('placeholder')
  )
}

// https://vite.dev/config/
export default defineConfig(({ mode }) => {
  const pwaEnv = loadEnv(mode, '.', 'VITE_')
  const backofficePublicEnv = loadEnv(
    mode,
    '../backoffice',
    'NEXT_PUBLIC_',
  )
  const supabaseUrl = isConfigured(pwaEnv.VITE_SUPABASE_URL)
    ? pwaEnv.VITE_SUPABASE_URL
    : backofficePublicEnv.NEXT_PUBLIC_SUPABASE_URL
  const supabaseAnonKey = isConfigured(pwaEnv.VITE_SUPABASE_ANON_KEY)
    ? pwaEnv.VITE_SUPABASE_ANON_KEY
    : backofficePublicEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY ||
      backofficePublicEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY

  return {
    define: {
      'import.meta.env.VITE_SUPABASE_URL': JSON.stringify(supabaseUrl ?? ''),
      'import.meta.env.VITE_SUPABASE_ANON_KEY': JSON.stringify(
        supabaseAnonKey ?? '',
      ),
    },
    plugins: [
      react(),
      tailwindcss(),
      VitePWA({
        registerType: 'autoUpdate',
        includeAssets: ['favicon.ico', 'apple-touch-icon.png', 'mask-icon.svg'],
        manifest: {
          name: 'MADS POS Kasir',
          short_name: 'MADS POS',
          description: 'Terminal kasir Management Distribution System',
          theme_color: '#0f172a',
          background_color: '#0f172a',
          display: 'standalone',
          orientation: 'landscape',
          icons: [
            {
              src: 'pwa-192x192.png',
              sizes: '192x192',
              type: 'image/png',
            },
            {
              src: 'pwa-512x512.png',
              sizes: '512x512',
              type: 'image/png',
            },
            {
              src: 'pwa-512x512.png',
              sizes: '512x512',
              type: 'image/png',
              purpose: 'any maskable',
            },
          ],
        },
      }),
    ],
  }
})

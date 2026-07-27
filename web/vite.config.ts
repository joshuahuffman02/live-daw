import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// The PCO Personal Access Token lives server-side (in .env, read here in the Vite dev
// server) and is injected into proxied requests — it never reaches the browser bundle,
// and the browser only ever calls same-origin `/pco/...`, which also avoids CORS.
// Keep this dev server on loopback by default because `/pco` is a credentialed proxy.
// In the shipping appliance this same call is made server-side by the device.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  return {
    plugins: [react(), tailwindcss()],
    server: {
      host: env.VITE_DEV_HOST || '127.0.0.1',
      proxy: {
        '/pco': {
          target: 'https://api.planningcenteronline.com',
          changeOrigin: true,
          secure: true,
          rewrite: (p) => p.replace(/^\/pco/, ''),
          configure: (proxy) => {
            proxy.on('proxyReq', (proxyReq) => {
              if (env.PCO_APP_ID && env.PCO_SECRET) {
                const tok = Buffer.from(`${env.PCO_APP_ID}:${env.PCO_SECRET}`).toString('base64')
                proxyReq.setHeader('Authorization', `Basic ${tok}`)
              }
            })
          },
        },
      },
    },
  }
})

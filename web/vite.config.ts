import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { tanstackRouter } from '@tanstack/router-plugin/vite'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const rootDir = path.dirname(fileURLToPath(import.meta.url))

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, rootDir, '')
  const apiProxyTarget =
    env.API_PROXY_TARGET || env.VITE_API_PROXY_TARGET || 'http://127.0.0.1:9090'
  const port = Number(env.DEV_PORT || env.VITE_DEV_PORT || 5173)

  return {
    plugins: [
      tanstackRouter({ target: 'react', autoCodeSplitting: true }),
      react(),
      tailwindcss(),
    ],
    resolve: {
      alias: {
        '@': path.resolve(rootDir, './src'),
      },
    },
    server: {
      port,
      proxy: {
        '/blog': {
          target: apiProxyTarget,
          changeOrigin: true,
        },
      },
    },
  }
})

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
    process.env.API_UPSTREAM ||
    env.API_UPSTREAM ||
    env.API_PROXY_TARGET ||
    env.VITE_API_PROXY_TARGET ||
    'http://127.0.0.1:9090'
  const port = Number(env.DEV_PORT || env.VITE_DEV_PORT || 5173)
  const previewPort = Number(process.env.PORT || env.PREVIEW_PORT || 4173)
  const apiProxy = {
    '/blog': { target: apiProxyTarget, changeOrigin: true },
    '/hello': { target: apiProxyTarget, changeOrigin: true },
  }

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
      host: true,
      allowedHosts: true,
      proxy: apiProxy,
    },
    preview: {
      port: previewPort,
      host: true,
      strictPort: true,
      allowedHosts: true,
      proxy: apiProxy,
    },
  }
})

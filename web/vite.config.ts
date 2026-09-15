import { defineConfig, loadEnv, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { tanstackRouter } from '@tanstack/router-plugin/vite'
import path from 'node:path'
import { Readable } from 'node:stream'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { fileURLToPath } from 'node:url'

const rootDir = path.dirname(fileURLToPath(import.meta.url))

const MEDIA_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

function allowedMediaUrl(raw: string): URL | null {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return null
  }
  if (url.protocol !== 'https:') return null
  const host = url.hostname.toLowerCase()
  const ok =
    host === 'github.com' ||
    host.endsWith('.github.com') ||
    host === 'githubusercontent.com' ||
    host.endsWith('.githubusercontent.com') ||
    host === 'amazonaws.com' ||
    host.endsWith('.amazonaws.com') ||
    host === 'cloudinary.com' ||
    host.endsWith('.cloudinary.com')
  return ok ? url : null
}

function mediaProxyPlugin(): Plugin {
  const handle = async (req: IncomingMessage, res: ServerResponse, next: () => void) => {
    const incoming = req.url ?? ''
    const pathOnly = incoming.split('?')[0]
    if (pathOnly !== '/media') {
      next()
      return
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.statusCode = 405
      res.end()
      return
    }
    let target: URL | null = null
    try {
      target = allowedMediaUrl(new URL(incoming, 'http://127.0.0.1').searchParams.get('u') ?? '')
    } catch {
      target = null
    }
    if (!target) {
      res.statusCode = 400
      res.end('invalid media url')
      return
    }
    try {
      const upstream = await fetch(target, {
        redirect: 'follow',
        headers: {
          Accept: '*/*',
          'User-Agent': MEDIA_UA,
        },
      })
      if (!upstream.ok || !upstream.body) {
        res.statusCode = upstream.status === 404 ? 404 : 502
        res.end('upstream media failed')
        return
      }
      res.statusCode = 200
      res.setHeader(
        'Content-Type',
        upstream.headers.get('content-type') || 'application/octet-stream',
      )
      res.setHeader('Cache-Control', 'private, max-age=600')
      const length = upstream.headers.get('content-length')
      if (length) res.setHeader('Content-Length', length)
      if (req.method === 'HEAD') {
        res.end()
        return
      }
      Readable.fromWeb(upstream.body as import('node:stream/web').ReadableStream).pipe(res)
    } catch {
      res.statusCode = 502
      res.end('upstream media failed')
    }
  }

  return {
    name: 'scorpio-media-proxy',
    configureServer(server) {
      server.middlewares.use(handle)
    },
    configurePreviewServer(server) {
      server.middlewares.use(handle)
    },
  }
}

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
    '/presentation': { target: apiProxyTarget, changeOrigin: true },
    '/hello': { target: apiProxyTarget, changeOrigin: true },
  }

  return {
    plugins: [
      mediaProxyPlugin(),
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

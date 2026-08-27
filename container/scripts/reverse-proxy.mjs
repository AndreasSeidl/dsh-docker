#!/usr/bin/env node
// dsh-container reverse proxy.
//
// DeepSeek Harness deliberately refuses to bind dsh web to 0.0.0.0 (its /api
// trust fence assumes a loopback or explicitly trusted deployment). To serve
// the GUI over a network -- which is what a container is usually for -- this
// proxy listens on the public bind, forwards to the loopback-only web app,
// and transports both plain HTTP and WebSocket upgrades.
//
// The /api trust fence accepts a request when both its Host and (present)
// Origin name a loopback authority. The proxy therefore rewrites Host and
// Origin to 127.0.0.1:<app-port> as it forwards. Because the page is served
// through this same proxy, the browser sees one same-origin origin and no
// CORS handling is needed (the harness sends no Access-Control-* headers).
//
// NOTE -- this is deliberately NOT an auth layer. It is the documented
// insertion point: adding Basic Auth (or any credential check) later means
// deciding allow/deny right here before forwarding. The optional
// DSH_WEB_TRUSTED_HOSTS allow-list below already restores a Host-level
// rebinding fence in front of the app for deployments that set it.
//
// Built for `node --` with zero runtime dependencies (node core only).

import { createServer, request as httpRequest } from 'node:http'
import { spawn } from 'node:child_process'
import net from 'node:net'

const APP_HOST = process.env.DSH_APP_HOST || '127.0.0.1'
const APP_PORT = Number(process.env.DSH_APP_PORT || 3081)

const rawBind = process.env.DSH_WEB_BIND || '0.0.0.0'
const PUBLIC_HOST = ['', '127.0.0.1', 'loopback', 'lo'].includes(rawBind) ? '127.0.0.1' : '0.0.0.0'
const PUBLIC_PORT = Number(process.env.DSH_WEB_PORT || 3080)

// Optional Host allow-list: when set, only these authorities are forwarded;
// everything else gets 403 (mirrors the app's own fence, moved in front).
const allowedHosts = (process.env.DSH_WEB_TRUSTED_HOSTS || '')
  .split(/[\s,]+/).map(h => h.trim().toLowerCase()).filter(Boolean)

function hostAllowed(host) {
  if (!allowedHosts.length) return true
  const bare = String(host || '').toLowerCase().replace(/:\d+$/, '')
  return allowedHosts.some(a => a.replace(/:\d+$/, '') === bare)
}

function remapHeaders(headers) {
  const out = { ...headers }
  out.host = `${APP_HOST}:${APP_PORT}`
  if (out.origin) {
    try {
      const u = new URL(out.origin)
      out.origin = `${u.protocol}//${APP_HOST}:${APP_PORT}`
    } catch {
      delete out.origin
    }
  }
  return out
}

function writeHeadLike(res, status, headers) {
  res.writeHead(status, headers)
}

// ── HTTP ────────────────────────────────────────────────────────────────
function forwardHttp(req, res) {
  if (!hostAllowed(req.headers.host)) {
    res.writeHead(403, { 'content-type': 'text/plain' })
    res.end('dsh: Host not allowed by DSH_WEB_TRUSTED_HOSTS\n')
    return
  }
  const options = {
    method: req.method,
    hostname: APP_HOST,
    port: APP_PORT,
    path: req.url,
    headers: remapHeaders(req.headers),
    agent: false,
  }
  const proxyReq = httpRequest(options, (proxyRes) => {
    const h = { ...proxyRes.headers }
    // Rewrite redirects that point back at the app so the browser stays on
    // the public origin.
    if (h.location && String(h.location).includes(`${APP_HOST}:${APP_PORT}`)) {
      h.location = String(h.location).replace(`${APP_HOST}:${APP_PORT}`, `${PUBLIC_HOST}:${PUBLIC_PORT}`)
    }
    writeHeadLike(res, proxyRes.statusCode || 502, h)
    proxyRes.pipe(res)
  })
  proxyReq.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' })
    res.end(`dsh: proxy error: ${err.message}\n`)
  })
  req.on('error', (err) => { if (!proxyReq.destroyed) proxyReq.destroy(err) })
  req.pipe(proxyReq)
}

// ── WebSocket upgrades ──────────────────────────────────────────────────
function forwardUpgrade(req, socket, head) {
  if (!hostAllowed(req.headers.host)) {
    socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n')
    socket.destroy()
    return
  }
  const options = {
    method: 'GET',
    hostname: APP_HOST,
    port: APP_PORT,
    path: req.url,
    headers: remapHeaders(req.headers),
    agent: false,
  }
  const proxyReq = httpRequest(options)
  proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
    socket.write('HTTP/1.1 101 Switching Protocols\r\n')
    for (const [key, value] of Object.entries(proxyRes.headers)) {
      if (key !== 'upgrade' && key !== 'connection') {
        socket.write(`${key}: ${value}\r\n`)
      }
    }
    socket.write('\r\n')
    socket.on('error', () => proxySocket.destroy())
    proxySocket.on('error', () => socket.destroy())
    if (proxyHead?.length) proxySocket.unshift(proxyHead)
    proxySocket.pipe(socket)
    socket.pipe(proxySocket)
  })
  // The app answered without upgrading (e.g. 403/500): relay that response.
  proxyReq.on('response', (proxyRes) => {
    const reason = proxyRes.statusMessage ? ` ${proxyRes.statusMessage}` : ''
    socket.write(`HTTP/1.1 ${proxyRes.statusCode}${reason}\r\n`)
    for (const [key, value] of Object.entries(proxyRes.headers)) {
      if (key !== 'connection' && key !== 'upgrade') socket.write(`${key}: ${value}\r\n`)
    }
    socket.write('\r\n')
    proxyRes.pipe(socket)
  })
  proxyReq.on('error', (err) => {
    socket.write(`HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\ndsh: proxy error: ${err.message}\n`)
    socket.destroy()
  })
  if (head?.length) proxyReq.write(head)
  proxyReq.end()
}

// ── the app process (dsh web), spawned so the whole web stack is one tree ──
const DSH_BIN = process.env.DSH_CONTAINER_BIN || '/usr/local/bin/dsh'
const dsh = spawn(DSH_BIN, ['web', ...process.argv.slice(2)], {
  stdio: 'inherit',
  env: process.env,
})
dsh.on('error', (err) => {
  console.error(`[dsh-proxy] failed to start dsh: ${err.message}`)
  process.exit(1)
})
dsh.on('exit', (code, signal) => {
  process.exit(code ?? (signal ? 1 : 0))
})

for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
  process.on(signal, () => {
    try { dsh.kill(signal) } catch { /* already gone */ }
  })
}

const server = createServer(forwardHttp)
server.on('upgrade', forwardUpgrade)

// Wait for the app to accept connections before publishing: dsh prints its URL
// line marginally before the listener is ready, and a request in that window
// would otherwise get a 502 from the proxy.
async function waitForApp(attempts = 120) {
  for (let i = 0; i < attempts; i++) {
    const up = await new Promise((resolve) => {
      const s = net.connect({ port: APP_PORT, host: APP_HOST })
      const done = (v) => { s.destroy(); resolve(v) }
      s.once('connect', () => done(true))
      s.once('error', () => done(false))
      s.setTimeout(500, () => done(false))
    })
    if (up) return true
    await new Promise((r) => setTimeout(r, 250))
  }
  return false
}

waitForApp().then((up) => {
  if (!up) {
    console.error(`[dsh-proxy] web app never came up on ${APP_HOST}:${APP_PORT}`)
    process.exit(1)
  }
  server.listen(PUBLIC_PORT, PUBLIC_HOST, () => {
    console.log(`[dsh-proxy] serving on http://${PUBLIC_HOST}:${PUBLIC_PORT} -> http://${APP_HOST}:${APP_PORT}`)
  })
}).catch((err) => {
  console.error(`[dsh-proxy] startup failed: ${err.message}`)
  process.exit(1)
})
server.on('error', (err) => {
  console.error(`[dsh-proxy] listen failed: ${err.message}`)
  process.exit(1)
})

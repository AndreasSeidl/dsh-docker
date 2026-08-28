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
// deciding allow/deny right here before forwarding. (An earlier
// DSH_WEB_TRUSTED_HOSTS Host allow-list was dropped: a Host-header check is
// not a security boundary -- any client can claim `Host: localhost` -- and the
// published port mapping is the real fence.)
//
// Built for `node --` with zero runtime dependencies (node core only).

import { createServer, request as httpRequest } from 'node:http'
import { spawn } from 'node:child_process'
import net from 'node:net'

// Both in-container ports are FIXED. The PROXY owns 3080 — the port upstream
// documents and everyone expects — so `docker run -p 3080:3080` and every
// `localhost:3080` in the harness's own docs just work.
//
// The web app itself is moved out of the way onto a high loopback-only port.
// It is never reachable from outside the container, and picking something
// obscure keeps it from colliding with the dev servers the agent starts inside
// the container (3000, 5173, 8080 ...). 30800 sits below the ephemeral range
// (32768+), so it can't clash with an outbound connection's source port either.
const APP_HOST = '127.0.0.1'
const APP_PORT = 30800
const PROXY_PORT = 3080 // fixed -- the port upstream documents; not a knob

// The listen address is NOT a knob. Inside its own network namespace the
// container has to bind every interface or a published port (`docker run -p`)
// has nothing to connect to — the namespace itself is the boundary, not this
// bind.
const PUBLIC_HOST = '0.0.0.0'
const PUBLIC_PORT = PROXY_PORT

// The port the GUI is published on from the USER's machine — the host side of
// `-p <port>:3080`. The container cannot discover it, so it is told through
// DSH_WEB_PORT. It exists so a clickable URL can be printed: `dsh web` 0.1.2+
// locks the session behind a per-run token it prints only in its ready-URL
// line, and that line must be rewritten to the public origin or the user can
// never open the GUI. (Compose passes DSH_WEB_PORT through automatically;
// `docker run` users set it to match their `-p <port>:3080`.)
const PUBLIC_URL_PORT = Number(process.env.DSH_WEB_PORT || 3080)
const PUBLIC_URL_BASE = `http://localhost:${PUBLIC_URL_PORT}`

// Who may reach the GUI is decided OUTSIDE the container, by the port mapping:
// `-p 127.0.0.1:3080:3080` (the default) means the kernel only ever accepts
// connections from this machine, and `-p 3080:3080` opens it to the network.
// That is a real boundary; a Host-header check in here would not be one (any
// client can claim `Host: localhost`), so this proxy does not pretend to be a
// LAN fence. See DSH_BIND_ADDRESS in docker-compose.yml / the README.

// There is deliberately NO Host allow-list: any client can claim any Host
// header, so one would not be a boundary -- the published port mapping is.

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
      h.location = String(h.location).replace(`${APP_HOST}:${APP_PORT}`, `localhost:${PUBLIC_URL_PORT}`)
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
// --port comes first so it can still be overridden by an explicit user flag in
// DSH_WEB_ARGS; keeping it here (rather than in the entrypoint) means the app
// port and the address the proxy forwards to can never drift apart.
// stdout and stderr are piped so the app's ready-URL line can be rewritten from
// its loopback origin to the public one (see READY_URL below); everything else
// passes through untouched, line-buffered.
const dsh = spawn(DSH_BIN, ['web', '--port', String(APP_PORT), ...process.argv.slice(2)], {
  stdio: ['ignore', 'pipe', 'pipe'],
  env: process.env,
})

// `dsh web` 0.1.2+ mints a per-run session token it prints only in its
// ready-URL line and 401s every request until the browser exchanges that token
// for an authority-bound cookie (a 303 + Set-Cookie). The proxy already
// forwards the whole token/cookie/redirect dance, so the only fix needed here
// is that the printed URL must be the public origin, not 127.0.0.1:30800.
const READY_URL = /^(dsh web: )(?:https?:\/\/)?127\.0\.0\.1:[0-9]+(\S*)\s*$/
function relayLines(out) {
  let buf = ''
  const onData = (chunk) => {
    buf += chunk
    let newline
    while ((newline = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, newline)
      buf = buf.slice(newline + 1)
      const m = line.match(READY_URL)
      out.write(m ? `${m[1]}${PUBLIC_URL_BASE}${m[2]}\n` : `${line}\n`)
    }
  }
  const onEnd = () => { if (buf) out.write(buf) }
  return { onData, onEnd }
}
const relayStdout = relayLines(process.stdout)
const relayStderr = relayLines(process.stderr)
dsh.stdout.setEncoding('utf8')
dsh.stderr.setEncoding('utf8')
dsh.stdout.on('data', relayStdout.onData)
dsh.stdout.on('end', relayStdout.onEnd)
dsh.stderr.on('data', relayStderr.onData)
dsh.stderr.on('end', relayStderr.onEnd)
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

#!/usr/bin/env node
// dsh-container: inject a crypto.randomUUID polyfill into the built web
// entry (apps/web/dist/index.html) so the UI works outside a secure context.
//
// Why: the frontend calls crypto.randomUUID() for message/RPC ids, which the
// browser only defines in a SECURE CONTEXT (https or localhost). A container
// served over plain HTTP on a LAN IP is an insecure context, so without this
// the realtime channel throws and never connects. Not a fork of the harness:
// a container-only inline classic script, inserted before the module bundle.
//
// Usage:  node inject-randomuuid-polyfill.mjs <path-to-index.html>
import { readFileSync, writeFileSync } from 'node:fs'

const file = process.argv[2]
if (!file) {
  console.error('usage: inject-randomuuid-polyfill.mjs <index.html>')
  process.exit(2)
}

const MARKER = 'id="dsh-randomuuid-polyfill"'
let html = readFileSync(file, 'utf8')
if (html.includes(MARKER)) {
  console.log('randomUUID polyfill already present; leaving unchanged')
  process.exit(0)
}

const POLYFILL =
  `<script ${MARKER}>/* dsh-container polyfill: crypto.randomUUID is undefined in ` +
  `non-secure contexts (plain-HTTP/LAN access). Backfill a UUIDv4 from ` +
  `getRandomValues. */ (function(){if(typeof globalThis.crypto!=="undefined"` +
  `&&typeof globalThis.crypto.randomUUID!=="function"){globalThis.crypto.` +
  `randomUUID=function(){var b=new Uint8Array(16);globalThis.crypto.` +
  `getRandomValues(b);b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;var h='';for(var ` +
  `i=0;i<16;i++){if(i===4||i===6||i===8||i===10)h+='-';var v=b[i].` +
  `toString(16);if(v.length<2)v='0'+v;h+=v;}return h;};}})();</script>`

const needle = '<script type="module"'
const idx = html.indexOf(needle)
if (idx === -1) {
  console.error(`no '<script type="module"' found in ${file}; not injecting`)
  process.exit(1)
}
html = html.slice(0, idx) + POLYFILL + '\n    ' + html.slice(idx)
writeFileSync(file, html)
console.log(`injected randomUUID polyfill into ${file}`)

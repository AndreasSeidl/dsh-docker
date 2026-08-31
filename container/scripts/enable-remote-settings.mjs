#!/usr/bin/env node
// dsh-container: patch the shipped (bundled) client UI so the Settings
// surfaces honor DSH_ALLOW_REMOTE_SETTINGS.
//
// Upstream gates Settings behind `ctx.remote.$host.isLoopback` (a client-side
// fact derived from the browser's page hostname): the settings mirror is built
// with persistence 'memory' — which drives the Models store to fail with
// "settings are unavailable in this browser" — and the General document store
// is dropped, whenever the browser is not on a loopback page. A GUI reached
// over a remote origin (a reverse-proxied or Tailscale/edge deployment)
// therefore can never configure providers through the web UI.
//
// This script ORs a runtime flag into both gates. The flag is injected into
// every served HTML document by reverse-proxy.mjs only when
// DSH_ALLOW_REMOTE_SETTINGS=1; without the flag the decision is byte-for-byte
// upstream's. Not a fork of the harness: a container-only replacement of two
// expressions in the bundled client, exactly like inject-randomuuid-polyfill.
//
// Fail-loud contract: each rule must match its target file EXACTLY once (the
// bundle bytes of the pinned harness version). A harness version bump that
// reformats or renames these statements aborts the build instead of silently
// not patching — extend the rules below, never weaken the match.
//
// Usage:  node enable-remote-settings.mjs <packages-root>   (e.g. /app/packages)

import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const root = process.argv[2]
if (!root) {
  console.error('usage: enable-remote-settings.mjs <packages-root>')
  process.exit(2)
}

// `globalThis.__DSH_ALLOW_REMOTE_SETTINGS__` is injected as an inline classic
// script into served HTML by reverse-proxy.mjs when DSH_ALLOW_REMOTE_SETTINGS=1.
// In a bundle the injected script runs before the module bundles (modules are
// deferred), so the flag is visible to every Settings decision.
const FLAG = 'globalThis.__DSH_ALLOW_REMOTE_SETTINGS__ === true'

// Each rule: file (relative to <packages-root>) + the exact byte strings to
// swap. Two forms per package because tsdown emits different quoting and
// structure in the bundled facade (lib/client.js) vs the per-module output
// (lib/types/client/index.js); both are patched so whichever the loader serves
// honors the flag.
const RULES = [
  // The settings-mirror persistence decision (drives "settings are unavailable
  // in this browser"): `isLoopback ? "host" : "memory"` → honor the flag too.
  {
    file: 'client/ui-settings/lib/client.js',
    search: 'const persistence = ctx.remote.$host.isLoopback ? "host" : "memory";',
    replace: `const persistence = ctx.remote.$host.isLoopback || ${FLAG} ? "host" : "memory";`,
  },
  {
    file: 'client/ui-settings/lib/types/client/index.js',
    search: "const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory';",
    replace: `const persistence = ctx.remote.$host.isLoopback || ${FLAG} ? 'host' : 'memory';`,
  },
  // The General tab's document controller (settings.yaml editing): only
  // constructed on a loopback page; gate it on the flag too.
  {
    file: 'client/ui-settings-general/lib/client.js',
    search:
      'const documentController = ctx.remote.$host.isLoopback ? new SettingsDocumentStore(ctx, ctx.settingsScope.describe()) : void 0;',
    replace:
      `const documentController = ctx.remote.$host.isLoopback || ${FLAG} ? new SettingsDocumentStore(ctx, ctx.settingsScope.describe()) : void 0;`,
  },
  {
    file: 'client/ui-settings-general/lib/types/client/index.js',
    search:
      'const documentController = ctx.remote.$host.isLoopback\n' +
      '        ? new SettingsDocumentStore(ctx, ctx.settingsScope.describe())\n' +
      '        : undefined;',
    replace:
      `const documentController = ctx.remote.$host.isLoopback || ${FLAG}\n` +
      '        ? new SettingsDocumentStore(ctx, ctx.settingsScope.describe())\n' +
      '        : undefined;',
  },
]

for (const rule of RULES) {
  const file = join(root, rule.file)
  if (!existsSync(file)) {
    console.error(`enable-remote-settings: missing ${rule.file} — harness layout changed?`)
    process.exit(1)
  }
  const source = readFileSync(file, 'utf8')
  if (source.includes(FLAG)) {
    console.log(`enable-remote-settings: ${rule.file} already patched; leaving unchanged`)
    continue
  }
  let count = 0
  let idx = -1
  for (let i = source.indexOf(rule.search); i !== -1; i = source.indexOf(rule.search, i + 1)) {
    count += 1
    if (idx === -1) idx = i
  }
  if (count !== 1) {
    console.error(
      `enable-remote-settings: expected the gate in ${rule.file} exactly once, found ${count}. ` +
        'A harness version bump may have reformatted the bundled client — update the ' +
        'rules in container/scripts/enable-remote-settings.mjs to the new bytes.',
    )
    process.exit(1)
  }
  writeFileSync(file, source.slice(0, idx) + rule.replace + source.slice(idx + rule.search.length))
  console.log(`enable-remote-settings: patched ${rule.file}`)
}

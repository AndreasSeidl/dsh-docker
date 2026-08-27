#!/usr/bin/env node
// @dsh-test/bundle-all — install-time side-effect marker.
//
// pnpm runs postinstall for every added package (the profile global config in
// the container allows build scripts, `dangerouslyAllowAllBuilds: true`). This
// writes a provenance record so the test suite can assert the install path —
// including lifecycle scripts — actually executed inside the container.
//
// Location: $DSH_HOME/dsh-test-bundle-postinstall.json (the harness home is
// on a volume, so the record survives container recreation); falls back to the
// package directory when DSH_HOME is absent (plain `npm install` on a host).
import { writeFile, mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'

const record = {
  script: 'postinstall',
  bundle: 'pkg:@dsh-test/bundle-all',
  pnpmVersion: process.env.npm_config_user_agent ?? null,
  nodeVersion: process.version,
  at: new Date().toISOString(),
}

const where = process.env.DSH_HOME
  ? join(process.env.DSH_HOME, 'dsh-test-bundle-postinstall.json')
  : join(process.cwd(), 'postinstall.json')

await mkdir(dirname(where), { recursive: true })
await writeFile(where, `${JSON.stringify(record, null, 2)}\n`)
console.log(`[dsh-test-bundle] postinstall ran -> ${where}`)

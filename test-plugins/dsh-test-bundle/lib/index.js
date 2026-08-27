// @dsh-test/bundle-all — the self-mounting sentinel plugin.
//
// A minimal Cordis plugin (object form: `{ name, apply(ctx, config) }`). The
// `dsh-test-sentinel` row this bundle's patch inserts mounts it into the
// running harness, proving an out-of-tree plugin — one that is not part of the
// dsh installation — is importable and applied by the loader at boot.
//
// Side effects (all used by the container test suite as assertions):
//   * writes `config.markerPath` (default /tmp/dsh-test-sentinel.marker) with
//     install-time + runtime provenance;
//   * logs one deterministic line to the harness stdout.
//
// Deliberately dependency-free: it must mount on the bare dsh-base profile
// with nothing else in the tree.
import { mkdir, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

const FALLBACK_MARKER = '/tmp/dsh-test-sentinel.marker'

export default {
  name: 'dsh-test-sentinel',
  async apply(ctx, config = {}) {
    const where = config.markerPath || FALLBACK_MARKER
    try {
      await mkdir(dirname(where), { recursive: true })
      await writeFile(where, `${JSON.stringify({
        marker: config.marker,
        bundle: 'pkg:@dsh-test/bundle-all',
        row: 'dsh-test-sentinel',
        pid: process.pid,
        cwd: process.cwd(),
        at: new Date().toISOString(),
      }, null, 2)}\n`)
      console.log(`[dsh-test-bundle] sentinel mounted -> ${where} (${config.marker})`)
    } catch (error) {
      console.error(`[dsh-test-bundle] sentinel marker write failed: ${String(error)}`, error)
    }
  },
}

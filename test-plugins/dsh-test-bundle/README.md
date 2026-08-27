# @dsh-test/bundle-all — DSH harness plugin test bundle (v0.1+)

A deliberately small, dependency-free bundle that exercises **every extension
surface a DSH plugin can use**, so a container/CI can prove that *any well-formed
plugin* works on a given harness build — not just ones that happen to install.

It targets the public **`dsh.bundle`** contract and behaves across the 0.1 line
(patch rows that a given harness version does not ship are skipped with a
warning, never fatal).

## What it proves, and how

| # | Capability | Mechanism | Assertion |
|---|-----------|-----------|-----------|
| 1 | Install path incl. lifecycle scripts | `scripts/postinstall.mjs` | writes `$DSH_HOME/dsh-test-bundle-postinstall.json` |
| 2 | Bundle registration / reconciliation | package.json `dsh: { bundle: { patch: ./cordis.patch.yml } }` | `dsh plugin --profile <p> add` adds it to `dsh.profile.bundles` |
| 3 | Patch-layer application at boot | `cordis.patch.yml` overrides `tool-bash` config with `testMarker` | `dsh --profile <p> --dump-default-config` contains the marker |
| 4 | A **new out-of-tree plugin mounts in-process** | patch `insert`s row `dsh-test-sentinel` → `name: @dsh-test/bundle-all` | boot writes `$DSH_HOME/dsh-test-sentinel.marker` + logs `[dsh-test-bundle] sentinel mounted` |
| 5 | `!!js` expressions in patches | `markerPath: !!js process.env.DSH_HOME + ...` | marker lands under the harness home (expression evaluated) |
| 6 | Agent-preset authoring | `presets/dsh-test-bundle/{agent.cordis.yml,preset.yml}` | copy into `$DSH_HOME/.agent-presets/` → discovered |
| 7 | Clean removal | `dsh plugin --profile <p> remove @dsh-test/bundle-all` | bundle leaves `dsh.profile.bundles`; patches stop applying |

## Layout

```
package.json                name/exports/files, dsh.bundle.patch, postinstall
cordis.patch.yml            the profile patch layer (override + insert)
lib/index.js                the self-mounting sentinel Cordis plugin
scripts/postinstall.mjs     install-time side-effect marker
presets/dsh-test-bundle/    sample agent preset (copy target)
```

## What plugins & presets can touch (short version)

See `../README.md` (the test-plugins overview) for the full surface. In brief:

* **A plugin** is a pnpm dependency of a profile plus, when its manifest
  declares `dsh.bundle.patch`, a *patch layer* applied over the shipped bundle
  layers. A patch may override/extend any boot row by id (`config`, `disabled`,
  `inject`, `intercept`, `isolate`, ...) and insert new rows (groups, services,
  tools, providers, web layer). Rows names import through the loader — bare
  names resolve from the profile directory — so a bundle can also *be* a plugin
  that mounts in-process (see `dsh-test-sentinel`).
* **An agent preset** is a directory of `agent.cordis.yml` + `preset.yml`
  discovered under `$DSH_HOME/.agent-presets/` (plus the shipped/system root).
  It composes everything an agent session uses — system prompt (persona), tool
  catalog, PTY/terminal stack, context policy — with the same trust as shell
  access.

## Run the container test suite

```bash
script="/repo/scripts/test-plugin-suite.sh"   # see the repo root Makefile
DSH_IMAGE=dsh:dev ./scripts/test-plugin-suite.sh
```

The suite drives the bundle through a real container: profiles `testbed` (bare
dsh-base) and `web` (full surface), asserting items 1–7 above and that a
subsequent `dsh web` boot stays healthy.

# Plan: Further DSH container build optimizations (round 2)

Status: proposal — none of this is implemented yet. **Test before adopt** is a
hard rule from round 1 (see `plans/LEARNINGS.md`): the "obviously faster"
`prune`/incremental-`--prod` approaches were rejected on measured tree
correctness. Every item below has a concrete experiment + acceptance check.

Sources of truth: `plans/LEARNINGS.md` (what worked / what failed, with
measurements), `bench/` (gitignored raw logs), the shipped `Dockerfile`.

Current state (round-1 shipped): source-edit iteration ≈ 103 s full / 122 s
builder, unchanged ≈ 2 s, clean warm build ≈ 110 s. Image 1.57 GB uncompressed /
~308 MB compressed. Biggest remaining costs: compile ~58 s **and** the ~50 s
prod conversation (both per source edit); biggest size items: apt toolchain
~390 MB + prod node_modules ~456 MB + base ~560 MB.

---

## Part A — further build-TIME cuts (highest priority)

### A1. Prod-deps split stage — decouple the ~50 s prod conversation from source edits (HIGH impact, MED effort, LOW-ish risk)
The prod `node_modules` content depends **only** on the lockfile + manifests,
never on source. Today the builder re-runs `rm -rf node_modules && pnpm install
--prod` after *every* source edit (~50 s).

Split it into its own stage keyed on the install inputs only:

- `FROM … AS prod-deps`: `COPY` lockfile + `pnpm-manifests/` + scripts + patches
  → `pnpm install --prod --offline` into `/prod/node_modules` (store on the same
  cache mount) → optionally `rm -rf` the store.
- `FROM … AS builder` (existing, but **without** the prod conversation): compile
  the tree as today (dev node_modules for the build).
- Runtime: `COPY --from=prod-deps /prod/node_modules /app/node_modules` +
  `COPY --exclude=node_modules --from=builder /build/ /app/`.

Expected: source-edit iteration ≈ 50 s lighter → **~55–65 s**; lockfile changes
still pay the conversion once. Risks to verify: a node_modules layer produced by
a *different* stage must satisfy the compiled tree — `heal-workspace-links`
already rebuilds member links at runtime, and pnpm store files are immutable, so
this should hold but **must be proven** by booting `dsh web` and the full suite.

Experiment: build a variant with the split; run (i) warm-up, (ii) one-line
source edit, (iii) one-line *lockfile* touch (mirror manifest) — time all three;
diff `/app` trees vs shipped image; then smoke/plugin/compose.

### A2. Incremental `tsc -b` + Vite cache via a cache mount — attack the 58 s compile (HIGH impact, MED-HIGH risk)
`tsc -b` is incremental *by design* but writes `.tsbuildinfo` into the build tree
(a fresh COPY layer per build → no reuse across builds). Persist that state (and
Vite's optimizer cache `node_modules/.vite`) on a `--mount=type=cache`:

```
RUN --mount=type=cache,target=/tscache \
    ( cp -a /tscache/. /build/ 2>/dev/null || true ) \
 && pnpm run build \
 && ( find /build -name '*.tsbuildinfo' -o -path '*/node_modules/.vite*' \
             | tar -c -T - | tar -x -C /tscache 2>/dev/null || true )
```

For a one-line edit, `tsc -b` should recompile only the affected project graph
instead of everything. Expected: compile 58 s → possibly high-20s/30s for small
edits (unproven — must measure per edit size).

Risks / gates:
- Stale/contradictory buildinfo must never produce a wrong `dist/`. Gate: build,
  edit, rebuild, then byte-diff `dist`/`lib` outputs **twice** (incremental path
  must equal a clean path) and boot the image.
- The `--ignore-scripts` manifest install copies into `/build` before the source
  `COPY`; deciding exactly which paths to restore is fiddly (tsbuildinfo for
  host + client + every package). If `tsc -b` fights the layer ordering, drop to
  Vite-cache-only or skip (compile stays the floor).
- Determinism check matters: the harness embeds `DSH_CLIENT_COMMIT_HASH` in the
  web bundle; confirm that isn't affected by hot buildinfo.

### A3. Parallelize the compile (MED impact, MED effort, test-gated)
First **measure the 58 s split** (tsc host vs tsc client vs tsdown vs Vite;
use `--progress=plain` logs or `build.ts` timings). Two candidate shapes:
- If host/client tsc+tsdown pairs are independent: `( tsc -b tsconfig.host.json
  && tsdown --env.DSH_BUILD_FACE host ) & ( tsc -b tsconfig.client.json &&
  tsdown --env.DSH_BUILD_FACE client ) & wait` then web.
- If the harness `scripts/build.ts` is the orchestrator, do NOT edit harness
  source in-tree — inject the parallel recipe via a build-stage script / RUN,
  so the compilation stays stock.

Gate: byte-identical `lib/`+`dist/` output vs the serial build, and a green web
boot. Honest target: 58 s → ~40–45 s (the web/Vite stage is likely still
serial). If output differs, abandon (round-1 rule: don't ship unproven wins).

### A4. Small cache mounts that compound (LOW effort, LOW risk)
- node-gyp build cache → `--mount=type=cache,target=/root/.cache/node-gyp`
  (reuse native addon builds when versions bump).
- pnpm resolution metadata → `~/.cache/pnpm` on a mount (slightly faster
  resolve on invalidations).
- apt `.deb` cache → `--mount=type=cache,target=/var/cache/apt/archives`
  (helps only when the apt layer invalidates; tiny otherwise).
These don't move the iteration number much; bundle them with A1/A2 PRs.

### A5. CI — verify the cold path stays warm, and add a first-run opt
Already shipped: `type=gha` + `type=registry,mode=max` caches. Additions:
- Confirm the registry `buildcache` ref actually pulls on amd64+arm64
  (buildx behaves; needs one real push test).
- Optionally a `nightly` schedule already warms the registry cache, so a Monday
  cold start should be the only "slow" run. Document expected first-run cost.

---

## Part B — further IMAGE shrink (secondary, no behavior loss)

### B1. Minimal *runtime* compile toolchain (LOW effort to investigate, HIGH impact if it works)
The 390 MB apt layer is `build-essential python3 pkg-config …`
(`build-essential` pulls dpkg-dev/fakeroot/etc.). Probe a minimal set that still
compiles the plugins we actually ship/test:

```
gcc g++ make python3 pkg-config   (vs)   build-essential python3 pkg-config
```

Experiment: build a scratch image with the minimal set and run the *plugin*
test (`node-pty`, plus try `sharp`); record `du` of `/usr/lib/gcc`,
`/usr/lib/x86_64-linux-gnu`, python. Gate: all plugin tests pass and
`docker images` delta is real (target ≥ 100 MB uncompressed). If node-pty
compiles but sharp needs libvips-dev etc., document the exact plugin matrix the
toolchain supports and keep the default conservative; optionally expose a
`DSH_INCLUDE_BUILD_TOOLS=minimal|full`.

### B2. Hard-link dedupe pass over `.pnpm` — reclaim the mount's cross-FS copies (MED impact, LOW-MED risk)
The cache-mount store (different FS) disables pnpm's peer-variant dedup → +10 MB
compressed vs round 0. A safe post-prod pass can re-link identical files:

```
find /app/node_modules/.pnpm -type f -print0 | sort -z \
 | xargs -0 sha256sum | sort | awk …  # group same-size+hash → ln -f
```

Store files are content-immutable, so hard-linking duplicates is logically safe
— but it touches thousands of files, so **gate loudly**: byte-diff a handful of
packages, `du` before/after, and run the suite. Claim at least the 10 MB back.

### B3. Carve out the dev junk still shipped (~9 MB + root `.tsbuildinfo`) (trivial, zero risk)
Measured leftovers in `/app`: `examples/` (5.1 M), `scripts/` (2.5 M — includes
the lefthook installer), `patches/`, `python/` (verify the agent tools don't
load it at runtime), plus root `AGENTS.md BENCHMARK.md BRAND_GUIDELINES* CLAUDE.md
CONTRIBUTING* README* THIRD_PARTY_NOTICES.md knip.json lefthook.yml pytest.ini
tsconfig*.json tsconfig.*.tsbuildinfo vitest*.ts tsdown.config.ts`.
Delete everything except LICENSE (+ README if desired) in the builder before the
runtime COPY, and extend the `*.tsbuildinfo` find to the whole `/build` root.
Compressed gain ~1–2 MB — do it because it's free, not because it's big.

### B4. Research (do not ship without data)
- Top-20 `.pnpm` virtual-store dirs today (from bench logs): 456 MB is mostly
  real runtime deps; flag any package that is opt-in feature bloat before
  pruning anything by hand.
- Base image: confirm `node:22-bookworm-slim` compressed contribution; revisit
  slim/trixie only if a switch is neutral for the native-addon ABI. Alpine stays
  out (musl vs koffi/sharp glibc prebuilds).
- `pnpm deploy --prod` shape: single-project only, so probably inapplicable to
  this multi-package runtime; note as rejected-by-design unless evidence
  contradicts.

---

## Priority order (my recommendation)

1. **A1** prod-deps split (biggest iteration win, low risk) — then re-measure.
2. **A2** incremental tsc/Vite (compile is now the floor; test carefully).
3. **B1** minimal toolchain probe (biggest single size win, constraint-bound).
4. **B2** hard-link dedupe (size), **A3** compile parallelism, **B3** junk
   carve-out, **A4** composite mounts.
5. A5 CI confirmation, B4 research.

## Acceptance criteria (measure, don't assume)

- [ ] Source-edit iteration ≤ ~70 s (from 103 s), with tree identical to a
      clean build (byte-diff `lib/`+`dist/`).
- [ ] Image size: compressed export ≤ 308 MB (B2 should bring it below the
      round-0 298 MB); uncompressed ≤ current.
- [ ] `dsh web` boots and SMOKE / PLUGIN / COMPOSE suites all PASS on the final
      image; plugin native compile still works with the shipped toolchain.
- [ ] GitHub Actions: second run not cold (gha/registry cache pulled).
- [ ] No harness source files modified in-tree for any speedup (all changes
      confined to the container layer).

## Verification methodology (from LEARNINGS.md)

Keep `bench/` logs; background builds (foreground bash is capped); mutate a
staged source file to simulate an edit and re-stage to restore; always run the
full suite after tree-changing steps; never edit a runner while it runs.

### Round-2 status — RESOLVED
- **A1 prod-deps split: DONE** (iteration 103 → 67 s; measured).
- **A3 parallel compile: DONE** (compile 55.6 → 38.5 s; byte-identical outputs
  verified; measured).
- **B1 minimal toolchain: DONE — NEUTRAL** (no size change; kept for surface;
  plugin test validates).
- **B2 hardlink dedupe: DONE** (6924 files linked; part of 308 → 303 M).
- **B3 dev-junk carve: DONE** (root tsbuildinfo/config/docs removed).
- **A2 incremental tsc state: TESTED — REJECTED** (compile stayed ~57 s both
  attempts; slower total; see LEARNINGS.md).
- **A4 small cache mounts / A5 CI warm confirm / B4 research: not pursued**
  (diminishing returns vs measured wins; CI caches already shipped in
  `.github/workflows/docker-publish.yml`).
- Final measured: warm 55 s, edit-iteration 67 s, steady-state 1.9 s,
  compressed export 303 M.

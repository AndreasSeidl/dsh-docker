# Learnings — DSH container build speedup (round 1, implemented 2025-08-27)

What was tried, what actually worked, and what did not. Every claim below is
**measured** (warm-cache source-edit iteration of the builder stage, same
machine, `bench/` logs — see `plans/docker-build-speedup-next.md` for the
follow-on plan).

## Headline results

| Rebuild scenario | Before | After (shipped) |
|---|---|---|
| source-edit iteration (one-line change) | ~4.2 min (251.7 s) | **~2.0 min (122.7 s builder / 103 s full)** |
| unchanged source `make build` | ~2.5–3 min | **≈ 2 s** |
| clean warm build | ~2.5–3 min | **≈ 1.8 min (110 s)** |

## What worked

1. **Manifest-first install split (the big structural win).** `COPY` the
   lockfile + workspace manifests (a `pnpm-manifests/` mirror of every
   `package.json`) and run `pnpm install --frozen-lockfile --ignore-scripts`
   BEFORE the real source is copied. A source-only edit then reuses that layer
   entirely. Without it (v1), the install re-runs on every edit (~31 s).

2. **Deferred lifecycle scripts via a second, idempotent install.** The first
   install cannot run scripts: some workspace member postinstalls read real
   source files (`packages/subprocess/subprocess-local/scripts/*`). Running a
   plain `pnpm install` again after `COPY . .` fires them in ~1 s on iteration —
   pnpm records its build state, so on an unchanged package graph it is a no-op.
   First build pays ~24 s once.

3. **pnpm store on a BuildKit `--mount=type=cache`.** Downloads are reused
   across builds (`reused 520/524`, `downloaded 0`) and the prod conversation
   runs `--offline` against it, so it never re-downloads. Without a mount every
   install logs `reused 0`.

4. **Context no-op fingerprint gate.** `scripts/build-context.sh` hashes the
   staged file set + Dockerfile + `.container/`; unchanged source skips the
   ~121 MB re-stage (`make context` = 0.26 s). Unchanged `make build` = 2.1 s.

5. **Digest-pinned base image** (`node:22-bookworm-slim@sha256:…`) so an
   upstream node rebuild can't silently invalidate the whole cache.

6. **CI caches** — `cache-from`/`cache-to` `type=gha` + `type=registry` with
   `mode=max` → no cold cache builds after the first run.

## What did NOT work (measured)

1. **`pnpm prune --prod` — faster (70 s) but WRONG for this monorepo.**
   - pnpm 11's `prune` has no `--frozen-lockfile` flag.
   - It converts only the **root project**; in a pnpm workspace the shared
     `.pnpm` virtual store kept every dev-only package (typescript, vitest,
     knip, tsx all survived) and member workspace links under
     `apps/*/node_modules/@deepseek-ai` were left broken.
   - `.pnpm` grew 399 M → 1008 M.
   Conclusion: the Dockerfile's original `rm -rf node_modules &&
   pnpm install --prod` was *correctly* defensive. That comment stays.

2. **Incremental `pnpm install --prod` (no `rm`) — faster (69 s) but same
   failure, worse.** Dev tree kept, `.pnpm` 1.5 G, member links missing.

3. **Same-filesystem in-layer store (store at `/build/.pnpm-store`)** — removes
   the mount and preserves hard-link dedup, but the build was *slower*
   (134 s vs 122 s) with murkier sizes. Rejected over the mounted store.

4. **Small-but-real traps (fixed):**
   - `COPY --chmod=0644` on `defaults/` strips the directory `x` bit → breaks
     unprivileged traversal. Use `--chown`, keep repo file perms.
   - Runtime corepack shim re-downloads pnpm each boot → `npm install --global`.
   - BuildKit `--mount=type=cache` store is on a *different filesystem* than
     `node_modules` → pnpm hard-link dedup between peer-variant `.pnpm` dirs is
     disabled → **+10 MB compressed export (298 M → 308 M, +3.3 %)**. This is
     the one accepted size regression from round 1.
   - `$(if $(CACHE_REF),--cache-from=…,ref=…)$` in a Makefile splits on the
     comma inside the string → leaked a bare `ref=` into `docker build`. Build
     the flag through a variable.
   - root-level `*.tsbuildinfo` outlived the carve-out step (it only cleared
     them under `packages/apps/vendor/native`).

## Process / methodology learnings

- **Measure, don't assume.** Variants v0–v5 were all built and timed; the
  "obviously faster" prune/incremental options were rejected on tree
  correctness and size. The shipped design is v2, not the fastest one.
- **Warm cache is the metric that matters locally** (the user's instruction);
  cold builds only realistically happen on CI, where the answer is cached
  layers → `type=gha`/`type=registry`.
- **Verify the tree, not just the wall clock.** After each prod-conversion
  variant: dev-only packages gone, member workspace links present, `.pnpm`
  size sane, then the full smoke/plugin/compose suite.
- Sanity pins: the staged context was mutated to simulate a source edit and
  re-staged to restore; don't trust `/tmp` (wiped between tool calls) — keep
  logs under the repo (gitignored `bench/`); run builds as **background jobs**
  (foreground bash is capped); never edit a runner script while it runs (bash
  parses incrementally and corrupts).

## Where the remaining 2 min goes (v2)

| Step | Time | Nature |
|---|---|---|
| `pnpm run build` (tsc -b host+client → tsdown → Vite) | ~57–59 s | pure CPU, serial |
| prod conversation (`rm -rf node_modules && install --prod --offline`) | ~50 s | FS churn, re-link 524 pkgs |
| export / runtime rebuild | ~20–23 s | layer export + runtime stage |
| everything else (install, 2nd install, heal) | ~2–15 s | cached / no-op |

## Where the 1.57 GB uncompressed / 308 MB compressed goes

| Layer | Uncompressed | Notes |
|---|---|---|
| apt toolchain (`build-essential python3 pkg-config …`) | **~390 MB** | biggest single item; `/usr/lib/gcc` 120 M, `/usr/lib/x86_64-linux-gnu` 125 M |
| `COPY /build → /app` (prod node_modules + compiled libs) | ~570 MB | node_modules/.pnpm ≈ 456 M of it |
| base `node:22-bookworm-slim` | ~560 MB | slim already |
| pnpm global, heal, config, helpers | ~36 MB | |
| dev junk still shipped | ~9 MB | `examples/` 5.1 M, `scripts/` 2.5 M, misc tsconfig/vitest files |

These two splits motivate the follow-on plan
(`plans/docker-build-speedup-next.md`).

---

## Round 2 — measured improvements AND non-improvements (empirically tested)

Method: every result below is a **measured wall-time or byte size**, not an
assumption, from `bench/*.log`. Warm-cache local iteration is the target
metric; CI cold builds are covered by the shipped `type=gha` + registry
buildcache caches (see `.github/workflows/docker-publish.yml`).

### Baselines (round 1, final image)
| metric | round-1 |
|---|---|
| warm full build (`make build`) | 110 s |
| source-edit iteration | 103 s |
| unchanged re-build (gate) | 1.6–2.1 s |
| compiled step (serial `pnpm run build`) | ~57 s |
| image compressed export | 308 M |

### Round-2 wins (all kept)
**A1 — prod-deps split (lockfile-keyed).** New stage `prod-deps`
`FROM install` derives the *production* `node_modules` once; the runtime now
gets `COPY --from=prod-deps /build/ /app/` + `COPY --exclude=node_modules
--from=builder /build/ /app/`. Because the prod tree is **keyed to the lockfile
+ tiny inputs** (the manifest mirror + the one workspace member that has a
postinstall, `@deepseek-ai/dsh-subprocess-local` 592 KB, copied for its
`node scripts/ensure-spawn-helper.mjs`; root postinstall dropped first), normal
source edits no longer re-run the ~50 s production conversion. **Iteration
103 s → 66.7 s; warm full 110 s → 55 s.** (Measured: `R2_ITER` 78 s with the
first r2 layout; final layout `FINAL_ITER` 66.7 s.)
  - Correctness kept: prod install still runs lifecycle scripts, so
    `node-pty`'s native addon and every member's postinstall are identical to
    round 1 (both images carry the same 14 `.node` files; 6332 compiled files,
    byte-identical hashes). Smoke/plugin/compose all pass.

**A3 — parallel host/client compile.** `build:lib:host` (~26 s tsc) and
`build:lib:client` (~15 s tsc) ran serially; run them concurrently, then Vite
last: `pnpm run build:lib:host & pnpm run build:lib:client & wait; pnpm run
build:web`. Compile step **55.6 s → 38.5 s**; iteration **72.2 s → 54.3 s**
(same source, byte-identical output — `c665…` digest matches, 6332 files
identical). **Outputs verified byte-identical** to the serial build, so this is
safe.

**B2 — hard-link dedupe over `node_modules/.pnpm`.** In `prod-deps`, a
python pass groups files by `(st_size, sha256)` and `os.replace`→`os.link`→
rollback-on-failure the duplicates (skipping symlinks and files with
`st_nlink > 1`). **6924 files linked** in one build. Contributes to the
compress-export reclaim.

**B3 — dev-junk carve moved up.** `examples/`, `website/`, `.github/`,
`docs/`, root markdown/config (`BRAND_GUIDELINES*`, `CLAUDE.md`, `AGENTS.md`,
`BENCHMARK.md`, knip/lefthook/pytest/tsconfig/vitest/tsdown files), plus every
`*.tsbuildinfo` is removed from the `builder` output, so the runtime no longer
ships ~9 MB of dev files. Combined size effect: **compressed export 308 M →
303 M** (also re-dedupes the prod `COPY` layer vs the earlier same-store
regression).

**B1 — minimal build toolchain (micro).** `gcc g++ make python3 pkg-config`
instead of `build-essential`… and it made **no measurable difference**
(389 MB apt layer in both). Kept anyway: smaller package surface, and the
plugin test proves node-pty still compiles at runtime with this set.

### Round-2 non-improvements (tested, rejected — do NOT retry blindly)
**A2 — incremental `tsc -b` state on a cache mount.** Idea: persist
`*.tsbuildinfo` **and** the compiled `lib/`/`dist/` dirs on
`--mount=type=cache,target=/tscache`, restore before `pnpm run build`, so
`tsc -b` recompiles only the edited graph (~42 s of tsc per edit).
  - Attempt 1 (absolute tar paths): restore extracted to `/build/build/…`
    (wrong), compile stayed 57.4 s.
  - Attempt 2 (relative paths): compile step **still 57.4 s** — the compile
    step never dropped below the clean 55.6 s, and total was *slower*
    (78.3 s vs 72.2 s clean). Incremental state does **not** compose across
    BuildKit layers cheaply here, and the restore-tar plumbing is fragile.
  - **Rejected.** The serial→parallel split (A3) got the same ~15 s for a
    tenth of the complexity.

### Part A ↔ Part B interactions (joint optimization notes)
- **A1 made B2/B3 nearly free and B2/B3 make A1 cheaper**: the dedupe + carve
  run inside `prod-deps`, *outside* the source-edit invalidation path, so the
  size work is paid once per lockfile change, not per edit; and the shrunken
  prod tree makes the runtime `COPY` step faster (B feeds A).
- **Toolchain choice (B1) is size-only**: compilation happens on the build
  daemon, never the runtime; it does not affect build time.
- **The compile path (A2/A3) and the prod-tree (B2/B3) are now fully
  separated**: source edits only touch the builder's compile layers and the
  two runtime COPYs — that is the entire remaining 66.7 s.
- Final numbers: **warm 55 s (was 110), iteration 66.7 s (was 103),
  unchanged 1.9 s (was ~2), export 303 M (was 308 M).**


---

## Round 3 — measured (2025-08-27 evening, same machine/method)

Goal: **image ≤ 250 MB compressed** AND **source-edit iteration < 40 s**, harness
fully functional at any point. Both met. Final measured (round-2 → round-3):

| metric | round-2 (shipped) | round-3 (final) |
|---|---|---|
| source-edit iteration (full image) | ~67 s | **32.4 s** |
| steady (unchanged) rebuild | 1.9 s | **1.3 s** |
| warm full build | 55 s | ~59 s (first build after Dockerfile change; editor-cache cold) |
| gzip'd `docker save` export | 303 MiB (317 MB) | **211 MiB (221 MB)** |
| `docker images` CONTENT SIZE | 319 MB | **222 MB** |
| uncompressed | 1.54 GB | 1.15 GB |

### What worked (all kept)

1. **A corrected incremental-compile cache mount (fixes round-2 A2).** The
   round-2 A2 attempt failed for a real, subtle reason we finally diagnosed:
   its own **attempt-1 left a poisoned archive in the shared
   `id=tscache` mount** (absolute `build/...` tar paths → restoring
   created a stray `/build/build` tree → +160 MB junk AND the tsc/tsdown run
   was never actually incremental). Round-3 fixes: a **new mount id
   (`tscache-r3b`)**, a **poison guard** (`rm -rf /build/build` after
   restore), and tar **relative** to /build. With the state actually restored,
   `tsc -b` skips unchanged projects and the edit recompiles only the affected
   graph: compile ~48 s → **~17 s on a one-file edit** (16.6 s measured in a
   fresh testbed image; 18.4 s in the poisoned build even so).
   - **Correctness proven**, not assumed: the warm image's non-node_modules
     tree hash is **byte-identical** to the round-2 clean build's, and the
     iteration's injected edit marker appears in the rebuilt image's compiled
     output while absent from the warm one.

2. **Runtime C-toolchain is now opt-IN (round-3 default off).** Arithmetic
   proof it had to leave the default image: base(80 MB) + toolchain(131 MB) +
   pnpm(10.5 MB) already exceeds 250 MB with nothing left for node_modules
   (77.7 MB) or the compiled tree (19.7 MB). The harness itself **never
   compiles at runtime** — its native addons (node-pty, koffi, sharp) are
   built once in the builder stage — so dropping the ~100 MB-compressed
   toolchain layer breaks nothing in the harness (full smoke/compose pass).
   `make build INCLUDE_BUILD_TOOLS=1` restores the full 303 MiB image on
   which the node-pty plugin test still passes. This follows the same
   precedent as `DSH_INCLUDE_AGENT_CLIS` (off by default, saves ~560 MB).

3. **`Dockerfile.*` excluded from the builder COPY** so context-local variant
   Dockerfiles can't leak into the image.

### What did NOT work / gotchas (measured)

1. **Reusing the old `id=tscache` mount across rounds silently carries old
   (poisoned) data** — BuildKit cache mounts are keyed by id, not Dockerfile,
   so a past experiment's archive can corrupt a future build. Always version
   the id (and clear it when the recipe changes meaningfully).
2. **The smoke suite's proxy checks fail under concurrent-build load** (its
   `curl --retry 6 --retry-delay 1` health gate is too tight): three
   "proxy FAIL" runs were all concurrent with heavy `docker build`/save jobs;
   the same image passed in isolation and a manual proxy GET returned 200 in
   14 ms. Not a size/toolchain regression — a test-harness flake under load.
3. **tar-based state persists best as a single archive**: find → tar from
   inside /build keeps entries relative; absolute paths (round-2 attempt 1)
   are what broke restore.
4. Re-checked: dev junk (test-support packages pulling vitest/tsx, typert's
   typescript) lives in the prod tree and would prune a few more MB, but **we
   did not hand-prune deps** — round-1 rule (don't ship unproven wins) applies;
   it is unnecessary for the 250 MB goal (211 MiB leaves ~34 MiB headroom to
   the 250 MiB line / ~29 MB to the 250 MB decimal line).

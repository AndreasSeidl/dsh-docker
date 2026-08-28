# Development — building and iterating on the container

This file is for people who work on this repository — the image build itself,
the build speed, the cache, and the repo layout. If you just want to **use** the
container, see [README.md](README.md). For how to verify changes and how to
contribute, see [TESTING.md](TESTING.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Repository layout

```
container/             files copied into the image with the source
  bin/docker-entrypoint.sh   env → `dsh web` flag mapping; seeds defaults
  defaults/           first-boot scaffolds: settings.yaml, AGENTS.md
  scripts/            reverse-proxy.mjs (network/proxy mode),
                      inject-randomuuid-polyfill.mjs,
                      heal-workspace-links.mjs
Dockerfile             multi-stage build (builder → runtime)
Makefile               build / run / publish / shell / clean targets
docker-compose.yml     hardened deploy wiring (proxy + volumes + read-only
                       rootfs); defaults to the published GHCR image and takes
                       DSH_IMAGE (local build override) / DSH_TAG (pin)
.github/workflows/docker-publish.yml   GHCR publishing on tags + weekly
scripts/build-context.sh  stages the pruned source build context
scripts/smoke-test.sh     boots the image and checks volumes/persistence/proxy
scripts/plugin-test.sh    installs a native plugin end-to-end (node-pty)
scripts/compose-test.sh   boots + verifies the hardened compose stack (read-only, caps, tmpfs, health)
plans/                 internal build-speed research notes (LEARNINGS.md,
                       docker-build-speedup-next.md) — history, not user docs
test-plugins/          the probe plugin + its own README (see TESTING.md)
```

Most of the work is wiring, not application code: the harness is consumed
unmodified from a checkout (`DSH_SRC`), the Dockerfile compiles it and keeps
only the production runtime, and `container/` + `scripts/` provide the
container-specific glue (entrypoint, proxy, polyfill, link-healing, tests).

## Makefile reference

| Target | Purpose |
|---|---|
| `make context` | Stage a pruned copy of the harness source into `.docker-context/` (no-op when unchanged) |
| `make build` | `docker build .docker-context` → `dsh:<TAG>` |
| `make tag` | Alias for `build` |
| `make run` | Run the GUI (proxy mode, both volumes, `-p <PORT>:<PORT>`) |
| `make shell` | Throwaway container with the same mounts, `/bin/bash` as `dsh` |
| `make push` / `make publish` | `docker push <image>` (log in first) |
| `make test-plugins` | Run the plugin test suite against `DSH_IMAGE` (see TESTING.md) |
| `make clean` | Remove `.docker-context/` and local experiment dirs |
| `make cache-prune` | Prune the local BuildKit cache back to `KEEP_STORAGE` (default 5G) |
| `make cache-reset` | Full BuildKit cache prune (`prune -af`; cold rebuild next) |

To run **your local build** through the hardened compose wiring (the
`docker-compose.yml` defaults to the published GHCR image), point it at the
local image:

```sh
make build                        # → dsh:dev
DSH_IMAGE=dsh:dev docker compose up -d --no-build
```

This is what `scripts/compose-test.sh` does (see TESTING.md).

### Build variables

| Variable | Default | Meaning |
|---|---|---|
| `DSH_SRC` | `../deepseek-harness` | path to the harness checkout to build from |
| `IMAGE` | `dsh` | image name without registry |
| `REGISTRY` | *(empty)* | registry prefix for publish, e.g. `ghcr.io/you` |
| `TAG` | `dev` | tag for build/publish |
| `INCLUDE_BUILD_TOOLS` | on (`1`) | bake the C/native toolchain (`gcc g++ make python3 pkg-config`) into the runtime so `dsh plugin add` can compile native addons; set `0` for a leaner image (plugin installs that need a compiler then fail) |
| `INCLUDE_AGENT_CLIS` | off (`0`) | bundle the codex/claude-agent CLI binaries (~560 MB) so `subagent_codex` / `subagent_claude_code` resolve |
| `CACHE_REF` | *(empty)* | registry cache ref to warm `docker build` from (e.g. the GHCR `:buildcache` the CI exports) |
| `PORT` | `3080` | host port for `make run` |
| `KEEP_STORAGE` | `5G` | BuildKit cache ceiling kept by `make cache-prune` |

The client build embeds a commit hash, so the Makefile passes the real short
commit of the staged source as `DSH_CLIENT_COMMIT_HASH` (falling back to a
fixed hash when the checkout is unavailable or not a git repo).

## How the image is built (for maintainers)

```
make context
  scripts/build-context.sh  ── pruned source copy + pnpm-manifests mirror +
                              + Dockerfile + container helpers (no-op when unchanged)
                                    │
docker build .docker-context        ▼
  ── builder (node:22-bookworm-slim, digest-pinned) ───────────────
     corepack pnpm 11.7.0
     → pnpm install --ignore-scripts    (manifest-first: lockfile + workspace
                                         manifests only — cached across source edits)
     → COPY the real source
     → pnpm install                     (idempotent — fires lifecycle scripts;
                                         ~1 s no-op on a source-only edit)
     → pnpm run build                   (libs + client + web)
     → pnpm install --prod --offline    (production closure from the cache-mount
                                         store; no re-download, hardlink-friendly)
     → prune agent-CLI binaries + dev src/tests
     (pnpm store on a BuildKit --mount cache: downloads/native compiles persist
      between builds; verified 100% install reuse on a source-only edit)
  ── runtime (node:22-bookworm-slim, digest-pinned) ───────────────
     COPY --from=builder /build → /app (compiled tree, prod deps)
     COPY .container/{bin,scripts} from the context (NOT the builder tree —
        editing any container helper reuses the whole builder cache)
     → heal-workspace-links.mjs /app      (restore prod workspace links)
     → inject-randomuuid-polyfill.mjs     (LAN/HTTP secure-context fix)
     bash, git, curl, ca-certificates, tini, pnpm (npm-global),
        + optional native toolchain (build-essential, python3)
     unprivileged `dsh` user; pnpm global config baked (build scripts + store)
     entrypoint (under tini): seed defaults → map env → `dsh web` / proxy
```

Two quirks the image works around, both documented in the Dockerfile:

- `pnpm install --prod` in an isolated-linker workspace drops the
  `node_modules/<workspace-dep>` symlinks that production code imports by bare
  specifier. `container/scripts/heal-workspace-links.mjs` restores exactly the
  links a full install would have made (idempotent, re-homed for the image
  path). It runs in the **runtime** stage, after the tree is copied to `/app`,
  so the restored links point at their final in-image locations (pnpm records
  absolute paths; the script re-homes them onto the deploy root).
- The root `postinstall` (dev-only lefthook git hooks) would fail a `--prod`
  install, so the runtime manifest drops that one script field before the prod
  install runs.

## Build speed (measured)

The builder isolates the expensive graph install from source edits: a
`pnpm-manifests/` mirror of every workspace `package.json` is copied and
installed first (`--ignore-scripts`), with lifecycle scripts deferred to a
second, idempotent install after the source lands (~1 s no-op on a source
edit). The pnpm store rides a BuildKit cache mount so downloads and native
compiles persist between builds. Warm-cache measurements (source-edit
iteration, same machine; `plans/LEARNINGS.md` and
`plans/docker-build-speedup-next.md` hold the full variant matrix, raw logs,
and the rounds history; round-3 numbers measured 2025-08-27):

| Rebuild scenario                           | round-1  | round-2  | round-3 (current) |
|--------------------------------------------|----------|----------|-------------------|
| source-edit iteration (one-line change)    | ~4.2 min | ~1.1 min | **~33 s**         |
| unchanged source (`make build` twice)      | ~3 min   | ~1.9 s   | **~1.5 s**        |
| clean warm-up build (cold editor cache)    | ~3 min   | ~55 s    | **~59 s** (first build after Dockerfile change) |

Round-3 now persists the **compile state** (every `lib/`, `dist/` and
`*.tsbuildinfo`) on a BuildKit cache mount, so `tsc -b` recompiles only the
affected project graph on a source edit (~48 s compile → ~17 s; outputs verified
byte-identical to a clean build). The prod-closure re-link was already split
into a lockfile-keyed stage in round-2, so source edits never pay it.
Trade-offs, all tested: `pnpm prune --prod` and incremental `--prod` installs are
faster but leave dev packages in a pnpm workspace's shared `.pnpm` store and break
member links, so the Dockerfile keeps the (correct) offline reinstall; the
cross-filesystem cache mount costs ~10 MB of compressed image size (+3%) versus no
mount. CI publishes/consumes `type=gha` + registry build caches, so Actions builds
start warm after the first run.

## Cache hygiene (keeping the build cache bounded)

Plain `docker build` retains its intermediate layers (BuildKit `mode=max`
semantics), so **the local build cache grows without bound** — the round-3
experiments reached ~100 GB back-to-back. Two things keep it manageable:

- **Bound it on demand:** `make cache-prune` runs
  `docker buildx prune -f --keep-storage=5G`, trimming the cache back to
  ~5 GB (the in-use layer set stays, so warm rebuilds keep working). For a
  zero-cache cold start use `make cache-reset` (full `prune -af`).
- **The incremental-compile cache is source-commit-keyed.** The Dockerfile
  persists compile state (`lib/`, `dist/`, `*.tsbuildinfo`) on a BuildKit cache
  mount so source-edit iterations recompile only the changed graph. That state
  is tagged with the source commit it was built from and **discarded whenever
  the staged source changes** — stale compile state from another harness
  version made warm builds non-deterministic (the earlier parallel host+client
  compile could also race `@deepseek-ai/*/remote` generation, so the build now
  uses upstream's own serial `build:lib:host → build:lib:client → build:web`
  order). Same-commit rebuilds stay warm (~2 s layer reuse / ~40 s incremental);
  cross-commit builds always start from a clean compile.

On CI the same effect is handled by the workflow (see CONTRIBUTING.md):
GitHub's Actions cache caps and evicts automatically, and the unbounded
registry buildcache was removed.

# syntax=docker/dockerfile:1
#
# DeepSeek Harness — containerized `dsh web`.
#
# Builds the harness from source (docs: "With no modification, it should be
# the same as pnpm dsh web") and produces a small runtime image that only
# carries the compiled packages, the production dependency closure, and the
# built web frontend. Multi-stage: the compile happens in `builder`; the
# `runtime` stage gets the final tree (built libs + prod node_modules) and a
# slim Debian base.
#
# Build context: the repo source staged by scripts/build-context.sh (see the
# Makefile) with the container helper files under `.container/` and a
# `pnpm-manifests/` mirror used by the layer-caching install below.
#
# ── Build speed notes ────────────────────────────────────────────────────────
# * Base image is DIGEST-PINNED so an upstream node:22 rebuild can't silently
#   invalidate the whole build cache.
# * The builder stage splits dependency installation from source compilation:
#   lockfile + workspace manifests (the pnpm-manifests mirror) are copied and
#   installed FIRST, so a source-only edit re-runs only the compile, not the
#   ~30 s dependency install.
# * pnpm's content store lives on a BuildKit `--mount=type=cache` (and the
#   node-gyp build cache alongside it), so repeated builds reuse downloaded
#   tarballs and native compiles even when a layer above them is invalidated.
# * The `--prod` conversion uses `--offline` against that same cache mount.
#   (Benchmarked: b150a55-era source, warm caches — see README "Build speed".)
# ─────────────────────────────────────────────────────────────────────────────
ARG NODE_VERSION=22
ARG NODE_BASE=node:${NODE_VERSION}-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

# ════════════════════════════════════════════════════════════════════════════
# Stage 1 — builder stages (pnpm → install → builder / prod-deps)
#
# Round-2 topology: the PRODUCTION dependency tree and the COMPILED source tree
# have different invalidation keys (lockfile vs source). Splitting them means a
# source-edit iteration pays only the compile + export, never a ~50 s prod
# re-install. `prod-deps` derives from `install` (lockfile-keyed), so it is
# cached across source edits; `builder` derives from `install` too and adds the
# source copy + compile on top.
# ════════════════════════════════════════════════════════════════════════════
FROM ${NODE_BASE} AS pnpm

# Native addons (node-pty, koffi) can fall back to source builds; give the
# build daemon a C toolchain so a missing prebuild never fails the install.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential python3 git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# pnpm — the repo pins `packageManager: pnpm@11.7.0`; keep the lockfile honest.
ENV PNPM_HOME=/opt/pnpm
ENV PATH="/opt/pnpm:${PATH}"
RUN corepack enable \
 && corepack prepare pnpm@11.7.0 --activate

# Deterministic, non-interactive pnpm behavior (no TTY purge prompts, etc.).
ENV CI=true

# pnpm's content-addressed store (and node-gyp's cache) live on BuildKit cache
# mounts: downloads and native compiles are reused across builds even when a
# layer above them is invalidated. (Runtime plugin installs use their own
# volume-backed store — this is builder-only.)
RUN mkdir -p /root/.config/pnpm \
 && printf '%s\n' 'storeDir: /pnpm-cache/store' 'update-notifier: false' \
      > /root/.config/pnpm/config.yaml

WORKDIR /build

# ── Layers-caching dependency install ────────────────────────────────────────
# Install-time inputs in isolation (source edits below reuse this layer):
#   * pnpm-workspace.yaml / pnpm-lock.yaml / package.json
#   * every workspace member's package.json (the pnpm-manifests mirror that
#     scripts/build-context.sh generates)
#   * the root postinstall script and the patches pnpm applies during install
# `--ignore-scripts`: some workspace member postinstalls need real source files
# that are not copied until the builder step; the second install (in builder)
# fulfills those lifecycle scripts against the intact tree.
FROM pnpm AS install
COPY pnpm-workspace.yaml pnpm-lock.yaml package.json ./
COPY scripts/install-lefthook.mjs scripts/
COPY patches/ patches/
COPY pnpm-manifests/ ./
RUN --mount=type=cache,target=/pnpm-cache \
    pnpm install --frozen-lockfile --ignore-scripts

# ── Compile stage (source-keyed) ─────────────────────────────────────────────
FROM install AS builder
ARG DSH_CLIENT_COMMIT_HASH=b150a55
ENV DSH_CLIENT_COMMIT_HASH=${DSH_CLIENT_COMMIT_HASH}
COPY --exclude=Dockerfile --exclude="Dockerfile.*" --exclude=.container --exclude=pnpm-manifests . ./
# Fulfil lifecycle scripts (root lefthook postinstall, node-pty/koffi/esbuild
# build scripts, workspace member postinstalls) now the source exists.
RUN --mount=type=cache,target=/pnpm-cache \
    pnpm install --frozen-lockfile
# Compile the host libs, client libs, and the web frontend (`pnpm run build`,
# the exact command the project's own dev flow uses).
# Build ORDER matters: `build:lib:host` first, then `build:lib:client`, then
# `build:web`. The client `tsc` imports `@deepseek-ai/*/remote` modules that the
# HOST build emits, so a parallel host+client run races on clean builds —
# upstream's own `build:lib` (`scripts/build.ts`) is serial for the same reason.
# Incremental compile: the compile state (lib/, dist/, *.tsbuildinfo) persists
# on a BuildKit cache mount so `tsc -b` recompiles only the affected project
# graph on a source-edit iteration. The state is KEYED TO THE SOURCE COMMIT it
# was produced from: if the staged source changes, the cached state is
# discarded and the clean build runs. Stale compile state from another source
# version made warm builds non-deterministic (tsdown MISSING_EXPORT on restored
# stale bundles); the commit marker makes that class impossible.
RUN --mount=type=cache,target=/pnpm-cache \
    --mount=type=cache,target=/tscache,id=tscache-r3b <<'R3INC'
set -e
# Restore the previous build's compiled state ONLY if it belongs to the same
# source commit (relative paths; see save()).
restore() {
  if [ -f /tscache/.source-commit ] \
     && [ "$(cat /tscache/.source-commit)" = "$DSH_CLIENT_COMMIT_HASH" ] \
     && [ -f /tscache/art.tar ]; then
    tar -C /build -xf /tscache/art.tar
    # Guard: a relative-path archive must never leave a stray /build dir
    # (round-2 A2 hit this; a poisoned mount restored build/... into /build).
    rm -rf /build/build
  else
    echo "tscache: source changed (had '$(cat /tscache/.source-commit 2>/dev/null || echo none)', now '$DSH_CLIENT_COMMIT_HASH') — compiling fresh"
    rm -f /tscache/art.tar
  fi
}
save() {
  rm -f /tscache/art.tar
  (cd /build \
    && { find . -path './node_modules' -prune -o -type d \( -name lib -o -name dist \) -print; } > /tmp/outdirs \
    && find . -name '*.tsbuildinfo' -not -path '*/node_modules/*' -print >> /tmp/outdirs \
    && tar -c -f /tscache/art.tar -T /tmp/outdirs)
  printf '%s' "$DSH_CLIENT_COMMIT_HASH" > /tscache/.source-commit
}
restore
pnpm run build:lib:host
pnpm run build:lib:client
pnpm run build:web
save
R3INC

# The root postinstall (lefthook git hooks) is dev-only; drop it from the
# runtime manifest.
RUN node -e "const fs=require('fs');const p='/build/package.json';const j=JSON.parse(fs.readFileSync(p,'utf8'));if(j.scripts&&j.scripts.postinstall)delete j.scripts.postinstall;fs.writeFileSync(p,JSON.stringify(j,null,2)+'\n')"
# Carve out dev-only/config/doc trees from the COMPILED tree before the
# runtime copy (node_modules is NOT copied from here at all — it comes from
# prod-deps). Keeps docs/examples/tests/build-config out of the image.
RUN rm -rf /build/examples /build/website /build/.github /build/docs \
      /build/BRAND_GUIDELINES.i18n.yaml /build/BRAND_GUIDELINES.md /build/BRAND_GUIDELINES.zh.md \
      /build/CLAUDE.md /build/AGENTS.md /build/BENCHMARK.md /build/knip.json /build/lefthook.yml \
      /build/pytest.ini \
      /build/CONTRIBUTING.i18n.yaml /build/CONTRIBUTING.md /build/CONTRIBUTING.zh.md \
      /build/THIRD_PARTY_NOTICES.md \
      /build/tsconfig.json /build/tsconfig.base.json /build/tsconfig.base.client.json \
      /build/tsconfig.host.json /build/tsconfig.client.json \
      /build/vitest.config.ts /build/vitest.e2e.config.ts /build/vitest.shared.ts \
      /build/vitest.snapshot.config.ts /build/vitest.web-stress.config.ts \
      /build/vitest.web.config.ts /build/vitest.web.perf.config.ts /build/tsdown.config.ts \
 && find /build/packages /build/apps /build/vendor /build/native \
      -name '*.tsbuildinfo' -delete \
 && find /build -maxdepth 1 -name '*.tsbuildinfo' -delete

# ── Production dependency tree (lockfile-keyed) ──────────────────────────────
FROM install AS prod-deps
# One workspace member (@deepseek-ai/dsh-subprocess-local, 592 KB) has a
# postinstall that reads its own source, so it is copied here; every other
# member exists as its manifest only (from pnpm-manifests/). This keeps the
# prod-deps layer keyed to the lockfile + tiny, rarely-changing inputs — ordinary
# source edits do NOT invalidate it (that is the whole point of round-2 A1).
COPY packages/subprocess/subprocess-local/ packages/subprocess/subprocess-local/
# The root postinstall (lefthook) is dev-only and would fail a --prod install.
RUN node -e "const fs=require('fs');const p='/build/package.json';const j=JSON.parse(fs.readFileSync(p,'utf8'));if(j.scripts&&j.scripts.postinstall)delete j.scripts.postinstall;fs.writeFileSync(p,JSON.stringify(j,null,2)+'\n')"
# Convert the full dev tree to a production-only layout. --offline reuses the
# store the install stage just populated (same cache mount, same build); on a
# truly cold build the dev install has already downloaded everything. Lifecycle
# scripts run (node-pty builds its native addon, subprocess-local runs its
# postinstall against the copied source).
RUN --mount=type=cache,target=/pnpm-cache \
    rm -rf node_modules \
 && pnpm install --prod --frozen-lockfile --config.confirmModulesPurge=false --offline
# The two agent-CLI platform binary packages (the codex and claude-agent-sdk
# native CLIs, ~560 MB for the pair) are omitted by default; `pnpm install
# --prod` above ran with dev packages, so they'd otherwise survive here.
# Match them by NAME glob across every linux arch (x64/arm64/...), never a
# version: upstream bumps these often, and a version-pinned rm silently keeps
# whatever newer version the current lockfile resolved — a clean ~300 MB image
# becomes ~550 MB the moment the harness is upgraded (claude-agent-sdk
# 0.3.220 -> 0.3.241, codex 0.147 -> 0.149). The tripwire below fails the build
# if the purge ever stops matching (a package rename, a new arch suffix), so a
# size regression cannot slip through silently again. The CI guard in
# .github/workflows/image-hygiene.yml is the independent second line: it also
# asserts package absence in the final image and a size ceiling before anything
# is tagged/published.
ARG DSH_INCLUDE_AGENT_CLIS=0
RUN if [ "${DSH_INCLUDE_AGENT_CLIS}" != "1" ]; then \
      rm -rf /build/node_modules/.pnpm/@anthropic-ai+claude-agent-sdk-linux-*@* \
             /build/node_modules/.pnpm/@openai+codex@*-linux-* \
             /build/node_modules/.pnpm/@openai+codex-linux-*@*; \
      find /build/node_modules -type l ! -exec test -e {} \; -delete; \
      leftover="$(find /build/node_modules/.pnpm -maxdepth 1 -type d \( \
            -name '@anthropic-ai+claude-agent-sdk-linux-*@*' \
            -o -name '@openai+codex@*-linux-*' \
            -o -name '@openai+codex-linux-*@*' \) -print | head -3)"; \
      if [ -n "$leftover" ]; then \
        echo "FATAL: purged agent-CLI packages are still present:" 1>&2; \
        echo "$leftover" 1>&2; \
        echo "The harness renamed/changed these packages — update the purge globs above." 1>&2; \
        exit 1; \
      fi; \
      echo "agent-CLI platform packages purged (none remain)"; \
    fi
# Round-2 B2: the cache-mount store lives on a different filesystem than
# node_modules, so pnpm could not hard-link identical files across the
# peer-variant .pnpm directories (that cost ~10 MB in round-1). Re-link
# identical files inside .pnpm by hash — content-immutable store files, so this
# is safe — and reclaim that (and more) in the published image.
RUN python3 - <<'EOFPY'
import os, hashlib, collections
root = '/build/node_modules/.pnpm'
groups = collections.defaultdict(list)
for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        p = os.path.join(dirpath, fn)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if os.path.islink(p) or not os.path.isfile(p) or st.st_nlink > 1:
            continue
        h = hashlib.sha256()
        with open(p, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        groups[(st.st_size, h.hexdigest())].append(p)
linked = 0
for (size, hsh), paths in groups.items():
    if len(paths) < 2:
        continue
    base = paths[0]
    for p in paths[1:]:
        try:
            os.replace(p, p + '.tmp')
            os.link(base, p)
            os.unlink(p + '.tmp')
            linked += 1
        except OSError:
            try:
                if os.path.exists(p + '.tmp'):
                    os.replace(p + '.tmp', p)
            except OSError:
                pass
print('hard-link dedupe: %d files linked' % linked)
EOFPY
# Drop build-only scaffolding that was mounted for the install (not runtime).
RUN rm -rf /build/scripts /build/patches /build/pnpm-manifests /build/pnpm-lock.yaml /build/node_modules/.cache

# ════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════
# Stage 2 — runtime: slim base, production node_modules, compiled artifacts.
# ════════════════════════════════════════════════════════════════════════════
FROM ${NODE_BASE} AS runtime

# Runtime OS packages: bash (the model-facing shell tools spawn it), git,
# curl (web tools + healthcheck), ca-certificates (TLS), and tini (PID 1:
# reaps the orphaned/zombie children an agent's shell commands leave behind).
# A C/native toolchain (gcc g++ make python3 pkg-config) is baked in so
# `dsh plugin add <pkg>` can compile native addons (node-pty, sharp, ...) at
# runtime when no prebuilt binary matches. It costs ~100 MB compressed (~317 MB
# image vs ~221 MB without); set DSH_INCLUDE_BUILD_TOOLS=0 to drop it for a
# leaner image (plugin installs that need a compiler will then fail).
ARG DSH_INCLUDE_BUILD_TOOLS=1
# Round-2 B1: build-essential drags in dpkg-dev/fakeroot/etc.; node-gyp only
# needs the compiler + python3 + make. Use the minimal set (still compiles
# node-pty-style addons); verified by scripts/plugin-test.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git tini \
      $(if [ "${DSH_INCLUDE_BUILD_TOOLS}" = "1" ]; then echo gcc g++ make python3 pkg-config; fi) \
 && rm -rf /var/lib/apt/lists/*

# pnpm stays available so `dsh plugin --profile <name> add <pkg>` works inside
# the container (the profile lives on the volume). Installed via npm rather
# than the corepack shim: a plain bin in /usr/local/bin that never tries to
# fetch or write a "corepack cache" at runtime (which is exactly what breaks
# under a read-only HOME / hardened deployment).
RUN npm install --global pnpm@11.7.0

# A dedicated non-root user. It owns the harness home and the workspace —
# dsh is a code-running agent and writes only to those volumes, never to the
# host.
RUN groupadd --system dsh \
 && useradd --system --gid dsh --home-dir /home/dsh --create-home --shell /bin/bash dsh

WORKDIR /app

# Final tree = prod dependency tree (from prod-deps, lockfile-keyed) + compiled
# source (from builder). Two COPYs: node_modules everywhere comes from
# prod-deps; the builder overlays only source/compiled output (no node_modules)
# so its dev deps never enter the image.
#
# The builder overlay drops only .map files: sourcemaps are the single
# largest chunk of build-time-only cruft (~20 MB) and are used solely for
# in-container source-mapped debugging, which nothing in the runtime
# (product, plugins, self-editing) consumes and which leaves the raw stack
# traces text identical. Keeping package src/ (the original TypeScript, ~21 MB)
# preserves readable in-image source for in-container dev agents and
# auditability at a smaller cost than the maps would. Measured vs baseline:
# overlay 87 -> 67 MB, layer export 5.9s -> 4.5s, gzip 303 -> 298 MiB.
# Verified against smoke/compose/plugin suites.
COPY --from=prod-deps --chown=dsh:dsh /build/ /app/
COPY --exclude=node_modules --exclude='**/*.map' --from=builder --chown=dsh:dsh /build/ /app/
COPY --chown=dsh:dsh .container/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chown=dsh:dsh .container/scripts/heal-workspace-links.mjs \
        .container/scripts/inject-randomuuid-polyfill.mjs \
        .container/scripts/reverse-proxy.mjs \
     /usr/local/lib/dsh-container/

# Write-once defaults the entrypoint seeds into an empty $DSH_HOME volume on
# first boot (never overwrites user files). Read-only once the image is built.
# (Files are 0644 in the repo; COPY preserves that and keeps dirs 0755 — do
# NOT use --chmod=0644 here: it would strip the x bit from the directory and
# break traversal for the unprivileged user.)
COPY --chown=root:root .container/defaults /opt/dsh/defaults

# Heal the workspace cross-links AFTER the copy: pnpm's `--prod` install leaves
# them missing/unreliable, and any links created under /build would point at
# absolute /build paths. Re-running the heal at /app rewrites every workspace
# dependency link to its final in-image location.
RUN node /usr/local/lib/dsh-container/heal-workspace-links.mjs /app

# Inject the crypto.randomUUID polyfill into the built web entry. randomUUID
# is only defined in BROWSER SECURE CONTEXTS (https or localhost), so a plain
# HTTP LAN/IP deployment would otherwise throw and the realtime channel hangs
# before the trust fence / proxy ever matter. A classic (non-module) script is
# inserted before the module bundle so it runs first. This is a container-only
# enhancement; the harness source is untouched.
RUN node /usr/local/lib/dsh-container/inject-randomuuid-polyfill.mjs /app/apps/web/dist/index.html

# `dsh` -> the built CLI entry, plus make the entrypoint executable.
RUN printf '%s\n' '#!/bin/sh' 'exec /usr/local/bin/node /app/apps/cli/lib/bin.js "$@"' > /usr/local/bin/dsh \
 && chmod +x /usr/local/bin/dsh /usr/local/bin/docker-entrypoint.sh

# The agent's default workspace: a writable scratch area the user backs with a
# volume (it is the directory the harness starts sessions in). Point
# DSH_WORKSPACE elsewhere to relocate it.
RUN mkdir -p /workspace && chown dsh:dsh /workspace

# Server mode workspace root + the browser shortcut. /workspaces is baked into
# the image (not just created at boot) so that an empty named volume mounted
# there inherits the dsh user's ownership and the operator can create
# per-workspace subdirectories inside it, and the /home/dsh/workspaces symlink
# makes the harness's in-app directory browser (which lists the home directory
# first) start at the workspace root. The symlink must be baked here because
# the hardened runtime rootfs is read-only — /home/dsh is not writable after
# boot. Harmless in Local mode (/workspaces just sits empty and unused).
RUN mkdir -p /workspaces && chown dsh:dsh /workspaces \
 && ln -s /workspaces /home/dsh/workspaces

# Everything harness-persistent lives under one root (default ~/.dsh). Mount a
# volume here — profiles, session history, credentials, settings, user agent
# presets — or point DSH_HOME at a dedicated directory under your volume.
ENV DSH_HOME=/home/dsh/.dsh
# Scratch dirs go to tmpfs-backed /tmp rather than the (possibly read-only)
# image home, so pnpm/node/git caches never need a writable $HOME. NOTE: the
# pnpm GLOBAL CONFIG explicitly stays at ~/.config/pnpm (baked below) — it must
# NOT be redirected to /tmp or the build-script allowance would be lost.
ENV XDG_CACHE_HOME=/tmp/.cache \
    XDG_DATA_HOME=/tmp/.local/share \
    XDG_STATE_HOME=/tmp/.local/state
RUN mkdir -p "$DSH_HOME" /home/dsh/.dsh/.pnpm-store \
 && mkdir -p /home/dsh/.config/pnpm \
 && printf '%s\n' \
      '# dsh-container: pnpm settings for the dsh user (baked at image build).' \
      '# Allow dependency build scripts: dsh plugin installs depend on postinstall' \
      '# hooks (prebuilt downloads, node-gyp compiles) running without approval.' \
      'dangerouslyAllowAllBuilds: true' \
      '# Content-addressed package store on the harness volume: persists and' \
      '# dedupes plugin installs across container recreations. (pnpm 11 reads' \
      '# this as `storeDir` in the config.yaml settings file, not store-dir.)' \
      'storeDir: /home/dsh/.dsh/.pnpm-store' \
      'update-notifier: false' \
      > /home/dsh/.config/pnpm/config.yaml \
 && chown -R dsh:dsh /home/dsh

# 3080 — the port upstream documents — is the bundled reverse proxy, and the
# port to publish (`docker run -p 3080:3080`). `dsh web` itself sits behind it
# on 127.0.0.1:30800, reachable only from inside the container.
EXPOSE 3080

# Curl the proxy so the whole chain (proxy -> app) decides health. The port is
# the fixed 3080 -- the proxy always listens there inside the container. Once
# the session lock arms, an unauthenticated GET / answers 401 (that is ALIVE,
# not sick): the app returns 502 only while the web stack is still coming up,
# so 2xx/3xx/401 mean healthy; anything else -- connection refused, 502 from the
# proxy, 000 on timeout -- means the chain is broken.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD sh -c 'code="$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/ || true)"; case "$code" in 2*|301|302|303|307|401) exit 0;; *) exit 1;; esac'

USER dsh
WORKDIR /app

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["web"]

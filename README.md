# DeepSeek Harness — container

Runs the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) web
GUI (`dsh web`) as a small Docker image. The image is **compiled from source**
at build time — it builds the package libraries, the client bundles, and the web
frontend exactly like the project's own `pnpm run build` — and then keeps only
the production runtime: built packages, a production-only dependency closure,
and the built browser app. Nothing else runs or mounts on top.

## What you get

| | |
|---|---|
| Default behavior | Identical to `pnpm dsh web`: serves the GUI on `http://127.0.0.1:3080`, uses `$DSH_HOME` (= `~/.dsh`) for all harness data, fetches the same model config (via `settings.yaml` / credentials on the volume). |
| Network mode | `DSH_WEB_PROXY=1` (set by `make run` and `docker-compose.yml`) adds a bundled reverse proxy: the web app stays loopback-only and the proxy publishes the port on the network — so the GUI *just works* over LAN/IP without extra config, and it is the documented place to add authentication later. |
| Footprint | ~500 MB tree base; see [Size](#size) for measured numbers. Native-build toolchain included by default so `dsh plugin add` can compile (opt out with `INCLUDE_BUILD_TOOLS=0`). |
| User | Runs as an unprivileged `dsh` user, under `tini` (PID 1), with a hardened compose profile (`read_only` rootfs, no capabilities, no privilege escalation, pid cap). |
| Config | Everything the harness exposes is reachable through environment variables (see [Configuration](#configuration)). |
| Runs anywhere | `node apps/cli/lib/bin.js` is the prebuilt CLI; there is no source, repo, or pnpm dev-tooling in the runtime image (pnpm remains so `dsh plugin` still works). |

> **Why a volume is mandatory**
> The harness *is* self-modifying by design. `$DSH_HOME` holds its profile
> directory (`profiles/web/...`), the user's own patch layer
> (`profiles/web/cordis.patch.yml`, hot-reloaded live), session history,
> `settings.yaml`, `.credentials.yaml`, and your user agent presets. In a
> container that directory must live on a **volume** or everything you do is
> lost the moment the container stops. Mount a named volume (or a host
> directory) at `/home/dsh/.dsh`.
>
> The agent also needs a **workspace** — the directory it reads and edits
> files in. The container starts sessions in `/workspace`; back that with a
> volume too (see [Workspaces](#workspaces)) or the model's work is equally
> ephemeral.

## Quick start

```sh
# 1. Build (stages a pruned copy of the harness source into .docker-context/,
#    then builds dsh:dev). Point DSH_SRC at your deepseek-harness checkout.
make build DSH_SRC=/path/to/deepseek-harness

# 2. Run the GUI: network-reachable via the bundled reverse proxy, persisting
#    both the harness home and the agent workspace.
make run                                   # dsh:dev at http://<this-host>:3080

# or, with Docker Compose (hardened):
make context                               # stage the build context first
docker compose up -d --build               # volumes dsh-home + dsh-workspace
open http://127.0.0.1:3080
```

If `3080` is already taken on the host, override the port end-to-end with
`DSH_WEB_PORT=3081 docker compose up -d --build` — compose publishes the mapped
port and the container listens on the same value.

First boot **seeds** the `$DSH_HOME` volume with a scaffold `settings.yaml`
(empty, so stock defaults apply) and `AGENTS.md` (the harness's fixed
user-global briefing, which the agent loads before every session), then
auto-initializes the `web` profile and prints the URL line
(`dsh web: http://127.0.0.1:3080`). Existing files are never overwritten.

### Standalone `docker run`

```sh
# Faithful mode — exactly `pnpm dsh web` (loopback only):
docker run -d --name dsh -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace dsh:dev

# Network mode — loopback app + bundled reverse proxy on 0.0.0.0:3080:
docker run -d --name dsh \
  -p 3080:3080 \
  -e DSH_WEB_PROXY=1 \
  -e DSH_WEB_BIND=0.0.0.0 \
  -e DSH_WEB_PORT=3080 \
  -v dsh-home:/home/dsh/.dsh \
  -v dsh-workspace:/workspace \
  dsh:dev

open http://127.0.0.1:3080
```

### Build & publish a specific tag

```sh
make build TAG=0.1.0                            # dsh:0.1.0
make publish TAG=0.1.0 REGISTRY=ghcr.io/you     # push ghcr.io/you/dsh:0.1.0
alias dshimg='docker run --rm -it -v dsh-home:/home/dsh/.dsh'
dshimg dsh:0.1.0 --profile headless "run the tests"      # other dsh modes work too
```

`make publish`/`make push` just runs `docker push` — log in with
`docker login` first. The tag name is passed through verbatim, so
`REGISTRY=ghcr.io/you IMAGE=dsh TAG=v1` → `ghcr.io/you/dsh:v1`.

### Where the data lives (the volume)

`$DSH_HOME` defaults to `/home/dsh/.dsh` inside the image. Whatever survives a
container restart lives under it:

```
/home/dsh/.dsh/
├── profiles/            # per-profile dirs: package.json, cordis.patch.yml (YOUR patch layer, hot-reloaded)
│   ├── node_modules/    # launcher-maintained flat plugin links (re-healed at every boot)
│   └── web/             # the auto-initialized web profile
├── .pnpm-store/         # pnpm content store for `dsh plugin add` (persists installs)
├── settings.yaml        # seeded on first boot; model selection, UI preferences
├── AGENTS.md            # seeded on first boot; your user-global instruction file
├── .credentials.yaml    # provider credentials (git-ignored upstream)
├── sessions/            # conversation history
├── storages/            # persisted storage domains
└── .agent-presets/      # agent presets you author
```

Mount either a **named volume** (`-v dsh-home:/home/dsh/.dsh`) or a **host
directory** (`-v ./my-dsh:/home/dsh/.dsh`).

### Workspaces

The harness's default workspace is the directory it runs from (`process.cwd`)
— for a container that is `/workspace`, created owned by the `dsh` user. The
web UI's model then reads and edits files there, so back it with a volume. A
**named volume** (`-v dsh-workspace:/workspace`, the default in `make run` and
`docker-compose.yml`) persists the agent's work across recreations; a **host
bind mount** lets it work directly on real code:

```sh
# agent works on the code at ./my-project (and only there):
docker run -d -p 3080:3080 \
  -e DSH_WEB_PROXY=1 -e DSH_WEB_BIND=0.0.0.0 \
  -v dsh-home:/home/dsh/.dsh \
  -v "$PWD/my-project":/workspace \
  dsh:dev
```

Relocate the workspace with `DSH_WORKSPACE=/some/other/dir`. If your harness
data and project files can share one volume, mounting a single volume at
`/home/dsh` covers both `$DSH_HOME` and (with `DSH_WORKSPACE=/home/dsh/workspace`)
the workspace — a separate backing volume is cleaner when you want to back up
or share the project independently of harness state.

> Inside the container the `dsh` user owns `/workspace`, `/home/dsh`, and the
> install at `/app`. Everything else (including the host filesystem) is
> reachable only through volumes you mount, so the agent can never touch
> host files outside the workspace and harness-home volumes. With the hardened
> compose profile the root filesystem is additionally read-only.

## Network access & the reverse proxy

The harness **refuses to bind `dsh web` to `0.0.0.0`** (safety: its `/api`
trust fence is built around loopback / explicitly trusted authorities) and its
frontend calls `crypto.randomUUID()`, which browsers only expose in *secure
contexts* (https/localhost) — so a plain-HTTP LAN/IP deployment needs two fixes.

The bundled proxy (in `container/scripts/reverse-proxy.mjs`, zero
dependencies) solves both without changing the harness:

- listens on `DSH_WEB_BIND:DSH_WEB_PORT` (**0.0.0.0:3080** in network mode) and
  forwards to the loopback-only app on `DSH_APP_PORT` (**3081**);
- rewrites `Host` and `Origin` to the loopback app as it forwards, so the
  `/api` fence sees a local request and the browser sees one same-origin page
  (the harness sends no CORS headers, so nothing else is needed);
- transports **WebSocket upgrades** (`/api/events.*` realtime) the same way;
- injects nothing — a tiny `crypto.randomUUID` polyfill is baked into the
  served `index.html` at image build (container-only, not a fork).

**It is deliberately NOT an auth layer.** When authentication is wanted later,
the proxy is the insertion point: decide allow/deny before forwarding (Basic
Auth, session, or put a Caddy/nginx in front on the host). Meanwhile the safer
deployments set `DSH_WEB_TRUSTED_HOSTS` to the authority users reach you by —
in proxy mode that becomes a **Host allow-list enforced by the proxy** (any
other `Host` gets `403`), restoring a DNS-rebinding fence in front of the app:

```sh
docker run -d -p 3080:3080 \
  -e DSH_WEB_PROXY=1 -e DSH_WEB_BIND=0.0.0.0 \
  -e DSH_WEB_TRUSTED_HOSTS=dsh.example.com \
  -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace \
  dsh:dev
```

## Plugin installs

`dsh plugin` is a thin pnpm forwarder (`dsh plugin --profile <name> add <pkg>`).
The image is set up so installs work with no extra steps:

- **pnpm is bundled** (required by `dsh plugin` and the `dshmarket` community
  market) and its global config bakes in `dangerouslyAllowAllBuilds: true` —
  dependency build scripts (prebuilt downloads and `node-gyp` compiles) run
  without interactive approval;
- a **C/native toolchain** (`build-essential`, `python3`, `pkg-config`) is in
  the runtime so plugins that compile native addons build even when no prebuilt
  binary matches (drop it with `INCLUDE_BUILD_TOOLS=0`);
- pnpm's **content store lives on the `$DSH_HOME` volume** (`.pnpm-store`), so
  installs are fast and survive container recreation.

```sh
# on the host:
docker run --rm -it \
  -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace \
  dsh:dev plugin --profile web add dshmarket          # community plugin market
# or from inside the container (dsh is on PATH):
dsh plugin --profile web add <package>
```

Installed plugins persist on `$DSH_HOME` and, once the profile reloads, appear
in the web UI's plugin list.

About the profile's bundle registry: the harness treats *server* plugins (packages
that declare a `dsh.bundle` manifest field) as profile layers and registers
them into `dsh.profile.bundles` automatically. A package that only declares
`dsh.bundle` when it is ready (e.g. some pre-1.0 community RCs) is installed
as a plain profile dependency — the CLI even prints
`declares no dsh.bundle — installed as a plain dependency, not a profile layer`
for those. To make a plain dependency load as a bundle, add its package name to
`dsh.profile.bundles` in `$DSH_HOME/profiles/web/package.json` (a manual step,
not something a pnpm forwarder can do for you).

**Test that any plugin works.** `test-plugins/` ships a probe bundle
(`@dsh-test/bundle-all`, 0.1+ API) that deliberately touches every plugin
extension surface: install scripts, `dsh.bundle` reconciliation, patch-layer
application at boot, an out-of-tree plugin mounting in-process (`!!js` included),
agent-preset authoring, and clean removal. `make test-plugins`
(`scripts/test-plugin-suite.sh`, targets runtime image `DSH_IMAGE`) runs it
end-to-end in real containers — 24 assertions, profiles `testbed` and `web`.


## Configuration

Nothing is compiled in beyond the stock `dsh web` defaults. Every harness knob
reaches the process through environment variables — the harness reads them from
its own layered environment, and `/usr/local/bin/docker-entrypoint.sh` maps the
web-facing ones onto `dsh web`'s flags.

### Web server

| Variable | Default | Maps to | Notes |
|---|---|---|---|
| `DSH_WEB_PROXY` | unset | proxies `web` | Non-empty turns on the bundled reverse proxy (loopback app + public proxy). Set it for any deployment reached beyond the host. |
| `DSH_WEB_PORT` | `3080` | public port (`--port` / proxy listen) | Both modes honor it; the healthcheck curls it. |
| `DSH_APP_PORT` | `3081` | app listen port (proxy mode) | Loopback port the web app binds in proxy mode. |
| `DSH_WEB_BIND` | `127.0.0.1` | webserver `host` via `--patch` (faithful) / proxy bind (proxy mode) | In faithful mode this is the harness listener (the CLI rejects `--host 0.0.0.0`, so the entrypoint uses a `--patch` overlay). In proxy mode it is the *proxy's* public bind and defaults to `0.0.0.0`. |
| `DSH_WEB_TRUSTED_HOSTS` | — | `--trusted-host` ×N (faithful) / proxy Host allow-list (proxy) | Space/comma-separated authorities: `dsh.example.com`, `192.168.1.50`, or `host:port`. |
| `DSH_WEB_NO_OPEN` | `1` | `dsh web --no-open` | Containers have no browser; set `0` to allow the browser-handoff path. Works on every host OS — the flag never spawns a platform launcher. |
| `DSH_WEB_ARGS` | — | raw extra args | Must start with `-`; for exotic flags. |
| `DSH_WORKSPACE` | `/workspace` | sets the process cwd (default workspace) | Back it with a volume; the agent works in this directory. |
| `DSH_HOME` | `/home/dsh/.dsh` | harness home | Point at a directory inside your volume if you prefer a dedicated layout. |

`localhost`, `127.0.0.1` and any `127.x` Host header are trusted by the `/api`
fence automatically, so loopback-only use needs none of the above.

### Harness & providers (pass straight through)

Set these like any container env var — no image changes needed:

- `DSH_TELEMETRY_DISABLED` — opt out of telemetry (`any non-empty value disables`).
- `DSH_TOOLS_MODE` — `native` / `code` / `both` tool presentation.
- `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL` — the shipped DeepSeek adapter
  (credentials can equally go in `.credentials.yaml` on the volume).
- Any pi-ai provider keys referenced from `settings.yaml` (e.g. `DGX_API_KEY`).
- `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`, `TZ`, `NODE_OPTIONS`, and every
  other variable the layered `.env` loader forwards.

> The default listener is loopback-only (`127.0.0.1`), matching `pnpm dsh web`.
> Use `DSH_WEB_PROXY=1` (recommended) for network reach — it needs no extra
> config; or faithful mode with `DSH_WEB_BIND=0.0.0.0` **and**
> `DSH_WEB_TRUSTED_HOSTS=<the name users type>`.

### Anything else

The container is a full `dsh` launcher, so every CLI mode works. Each example
mounts both the harness-home and the workspace volumes:

| Command | Container |
|---|---|
| Web GUI | default (`web`, faithful loopback) |
| One-shot task | `docker run --rm -it -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace dsh:dev --profile headless "run the tests"` |
| Inspect the composed profile | `docker run --rm -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace dsh:dev --profile web --dump-default-config` |
| Install a plugin into a profile | `docker run --rm -it -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace dsh:dev plugin --profile web add <package>` |
| Edit your patch layer | edit `profiles/web/cordis.patch.yml` on the volume — it hot-reloads |

The default agent preset is `standard`; its codex/claude delegation tool rows
are mounted but their CLI binaries are **not** shipped by default (that saves
~560 MB — `/openai/codex` & `claude-agent-sdk` platform packages are only
resolved when the model actually invokes `subagent_codex`/`subagent_claude_code`).
Rebuild with `INCLUDE_AGENT_CLIS=1` to bundle them:

```sh
make build TAG=edge INCLUDE_AGENT_CLIS=1
```

## Size

Measured for the default build (no agent CLIs), `linux/amd64`:

- **~1.5 GB uncompressed, ~300 MB when pulled/transferred (compressed)** with
  the native-build toolchain included (the default).
- `make build INCLUDE_BUILD_TOOLS=0` drops the compiler/python3 set for a
  leaner image (~1.1 GB uncompressed / ~220 MB compressed); `dsh plugin add`
  of packages that need a native compile will then fail.

The toolchain is kept by default because "plugin installs work" beats a few
tens of MB of compressed size; set the flag for a minimal runtime.

## CI: automatic publishing on release tags

A GitHub Actions workflow (`.github/workflows/docker-publish.yml`) builds and
pushes to GHCR:

- **on every tag** — `git tag v0.1.1-rc.2` (or `0.1.1-rc.2`) pins the harness
  at that upstream version and publishes
  `ghcr.io/<owner>/dsh-container:<version>` and `:latest`;
- **weekly (Mon 03:30 UTC)** — rebuilds the upstream default branch as
  `ghcr.io/<owner>/dsh-container:nightly`;
- **manually** — `workflow_dispatch` accepts a `version` (tag or commit) input.

Both `linux/amd64` and `linux/arm64` are built and pushed. Tags in the recipe
repo and harness versions map 1:1 (`v`-prefix optional).

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

### Build speed (measured)

The builder isolates the expensive graph install from source edits: a
`pnpm-manifests/` mirror of every workspace `package.json` is copied and installed
first (`--ignore-scripts`), with lifecycle scripts deferred to a second, idempotent
install after the source lands (~1 s no-op on a source edit). The pnpm store rides
a BuildKit cache mount so downloads and native compiles persist between builds.
Warm-cache measurements (source-edit iteration, same machine, `plans/docker-build-speedup.md`
has the full variant matrix and raw logs):

| Rebuild scenario                           | Before   | After          |
|--------------------------------------------|----------|----------------|
| source-edit iteration (one-line change)    | ~4.2 min | **~2.0 min**   |
| unchanged source (`make build` twice)      | ~2.5–3 min | **≈ 5–10 s** |
| clean warm-up build                        | ~2.5–3 min | **~1.8 min** |

The remaining ~2 min on a source edit is the actual compile (`pnpm run build`,
~58 s — pure CPU, not cacheable) plus the production-closure re-link (~50 s).
Trade-offs, all tested: `pnpm prune --prod` and incremental `--prod` installs are
faster but leave dev packages in a pnpm workspace's shared `.pnpm` store and break
member links, so the Dockerfile keeps the (correct) offline reinstall; the
cross-filesystem cache mount costs ~10 MB of compressed image size (+3%) versus no
mount. CI publishes/consumes `type=gha` + registry build caches, so Actions builds
start warm after the first run.

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

## Development layout

```
container/             files copied into the image with the source
  bin/docker-entrypoint.sh   env → `dsh web` flag mapping; seeds defaults
  defaults/           first-boot scaffolds: settings.yaml, AGENTS.md
  scripts/            reverse-proxy.mjs (network/proxy mode),
                      inject-randomuuid-polyfill.mjs,
                      heal-workspace-links.mjs
Dockerfile             multi-stage build (builder → runtime)
Makefile               build / run / publish / shell / clean targets
docker-compose.yml     hardened wiring (proxy + volumes + read-only rootfs)
.github/workflows/docker-publish.yml   GHCR publishing on tags + weekly
scripts/build-context.sh  stages the pruned source build context
scripts/smoke-test.sh     boots the image and checks volumes/persistence/proxy
scripts/plugin-test.sh    installs a native plugin end-to-end (node-pty)
scripts/compose-test.sh   boots + verifies the hardened compose stack (read-only, caps, tmpfs, health)
```

## Notes / limitations

- **Auth**: there is none yet, by design. Expose beyond a trusted network only
  with the `DSH_WEB_TRUSTED_HOSTS` allow-list set, TLS, or the future auth
  layer in the proxy.
- **Codex/Claude delegation** without `INCLUDE_AGENT_CLIS=1` follows the
  upstream model: the tool rows mount, and a call fails with a missing-binary
  error (equivalent to running `dsh web` on a machine without those CLIs).
- **Host-bound workspaces**: a bind-mounted `/workspace` owned by a different
  uid can make `git` warn about "dubious ownership"; run
  `git config --global --add safe.directory /workspace` via the container shell
  if you hit it (in hardened mode, HOME is read-only — use
  `-c safe.directory=/workspace` instead, or the `GIT_CONFIG_*` envs).
- The macOS/Windows-only surfaces (PowerShell, native directory picker) are
  inert on Linux; `--no-open` is host-agnostic, so the web mode behaves the
  same on macOS/Windows Docker Desktop hosts.
- The landlock sandbox binary is not shipped (it needs built-in kernel
  support); the sandbox stack degrades to its environment-defined fallback as
  it does on any unsupported host.
- Custom agent presets you author belong in `$DSH_HOME/.agent-presets/` on the
  volume (they carry the same trust as shell access, upstream's own rule).
- Healthcheck curls the configured `DSH_WEB_PORT` (default 3080) on loopback —
  the proxy (when enabled) answers it.

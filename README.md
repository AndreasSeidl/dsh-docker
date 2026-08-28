# DeepSeek Harness — container

Runs the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) web
GUI (`dsh web`) as a prepackaged, hardened Docker image. The image is compiled
from the harness source at build time and keeps only the production runtime —
you deploy it, you don't build it. The image is published to GHCR as
[`ghcr.io/andreasseidl/dsh-docker`](https://github.com/AndreasSeidl/dsh-docker/pkgs/container/dsh-docker).

## What you get

| | |
|---|---|
| Behavior | Identical to `pnpm dsh web`: serves the GUI on `http://127.0.0.1:3080`, uses `$DSH_HOME` (= `~/.dsh`) for all harness data, and reads model config from `settings.yaml` / credentials on your volume. |
| Network | Reachable over LAN/IP out of the box via a bundled reverse proxy (loopback-only in faithful mode); see [Network access](#network-access--the-reverse-proxy). |
| Hardened | Runs as an unprivileged `dsh` user under `tini` (PID 1); the compose profile adds `read_only` rootfs, no capabilities, no privilege escalation, and a pid cap. |
| Config | Everything the harness exposes is reachable through environment variables or `settings.yaml` on the volume — see [Configuration](#configuration). |
| Plugins | `dsh plugin` (pnpm forwarder) works; the runtime carries pnpm + a C/native toolchain so native plugins compile. |
| Size | ~303 MiB transferred-compressed; see [Size](#size) for measured numbers. |

## Deploy

The image is on GHCR — there is no build step. Both examples below create the
same two volumes (`dsh-home` for harness data, `dsh-workspace` for the agent's
work) automatically on first run.

### Docker Compose (recommended)

```sh
docker compose up -d          # pulls the published image and runs the hardened stack
open http://127.0.0.1:3080
```

The [docker-compose.yml](docker-compose.yml) ships the hardened profile: reverse
proxy enabled, both volumes declared, read-only rootfs, dropped capabilities.
Stop with `docker compose down` (keeps your data) or `docker compose down -v`
(removes the volumes too).

### `docker run`

```sh
# Minimal — loopback only, exactly `pnpm dsh web`:
docker run -d --name dsh \
  -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace \
  ghcr.io/andreasseidl/dsh-docker:latest

# Network reachable (LAN/IP) — loopback app + bundled reverse proxy:
docker run -d --name dsh -p 3080:3080 \
  -e DSH_WEB_PROXY=1 -e DSH_WEB_BIND=0.0.0.0 -e DSH_WEB_PORT=3080 \
  -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace \
  ghcr.io/andreasseidl/dsh-docker:latest

open http://127.0.0.1:3080
```

Stop with `docker stop dsh && docker rm dsh` (the named volumes survive
removal, so your data is kept).

### Picking a tag

- **`:latest`** — the latest released version (what you want to try it out).
- **`:<version>`** — a pinned release, e.g. `0.1.1-rc.2` (pin this in
  production / for reproducibility).
- **`:nightly`** — a weekly rebuild of the harness's default branch, "latest
  source" rolling.

Compose also honors a pinned tag: `DSH_TAG=0.1.1-rc.2 docker compose up -d`.

### First boot

On first boot the image **seeds** the `$DSH_HOME` volume with a scaffold
`settings.yaml` (empty, so stock defaults apply) and `AGENTS.md` (the harness's
user-global briefing the agent loads before every session), then
auto-initializes the `web` profile and prints
`dsh web: http://127.0.0.1:3080`. Existing files are never overwritten.

## Volumes & data

> **Why a volume is mandatory**
> The harness *is* self-modifying by design. `$DSH_HOME` holds its profile
> directory (`profiles/web/...`), the user's own patch layer
> (`profiles/web/cordis.patch.yml`, hot-reloaded live), session history,
> `settings.yaml`, `.credentials.yaml`, and your user agent presets. In a
> container that directory must live on a **volume** or everything you do is
> lost the moment the container stops.

The container uses two mounted paths, both backed by named volumes by default:

| Path in container | What it is | Back it with |
|---|---|---|
| `/home/dsh/.dsh` | the harness home (`$DSH_HOME`): **all** persistent harness data | a named volume (`dsh-home`) or a host directory |
| `/workspace` | the agent's **workspace** — the directory it reads and edits files in | a named volume (`dsh-workspace`) or a host bind mount of real code |

The agent's work is equally ephemeral without a workspace volume — mount one or
the model can't persist any file it creates. To work on real code instead of a
private volume, bind-mount a project directory:

```sh
# agent works on the code at ./my-project (and only there):
docker run -d -p 3080:3080 \
  -e DSH_WEB_PROXY=1 -e DSH_WEB_BIND=0.0.0.0 \
  -v dsh-home:/home/dsh/.dsh \
  -v "$PWD/my-project":/workspace \
  ghcr.io/andreasseidl/dsh-docker:latest
```

With compose, edit [docker-compose.yml](docker-compose.yml) to bind `./workspace`
(or another host dir) instead of the `dsh-workspace` volume.

What survives a restart lives under `$DSH_HOME`:

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

Relocate either path with `DSH_HOME` / `DSH_WORKSPACE`. If you mount a **host
directory** instead of a named volume, pick the directory explicitly
(`-v ./my-dsh:/home/dsh/.dsh`); a named volume is otherwise the most convenient.

> Inside the container the `dsh` user owns `/workspace`, `/home/dsh`, and the
> install at `/app`. Everything else (including the host filesystem) is
> reachable only through volumes you mount, so the agent can never touch host
> files outside the workspace and harness-home volumes. With the hardened
> compose profile the root filesystem is additionally read-only.

## Configuration

Nothing is compiled into the image beyond the stock `dsh web` defaults. Every
harness knob reaches the process through environment variables — the harness
reads them from its own layered environment, and
`/usr/local/bin/docker-entrypoint.sh` maps the web-facing ones onto
`dsh web`'s flags. Model selection, UI preferences, and provider settings can
equally live in `settings.yaml` / `.credentials.yaml` on the volume.

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

**Port overrides end-to-end.** If `3080` is taken, choose another port once and
compose publishes it on the host and the container listens on the same value:

```sh
DSH_WEB_PORT=3081 docker compose up -d    # → http://127.0.0.1:3081
```

### Harness & providers (pass straight through)

Set these like any container env var (compose: under `environment:` or in a
`.env` file) — no image changes needed:

- `DSH_TELEMETRY_DISABLED` — opt out of telemetry (`any non-empty value disables`).
- `DSH_TOOLS_MODE` — `native` / `code` / `both` tool presentation.
- `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL` — the shipped DeepSeek adapter
  (credentials can equally go in `.credentials.yaml` on the volume).
- Any pi-ai provider keys referenced from `settings.yaml` (e.g. `DGX_API_KEY`).
- `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`, `TZ`, `NODE_OPTIONS`, and every
  other variable the layered `.env` loader forwards.

> The default listener is loopback-only (`127.0.0.1`), matching `pnpm dsh web`.
> Use `DSH_WEB_PROXY=1` (recommended — it is on by default in `make run` and
> docker-compose.yml) for network reach, no extra config; or faithful mode with
> `DSH_WEB_BIND=0.0.0.0` **and** `DSH_WEB_TRUSTED_HOSTS=<the name users type>`.

## For power users

### Network access & the reverse proxy

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
  ghcr.io/andreasseidl/dsh-docker:latest
```

### Plugin installs

`dsh plugin` is a thin pnpm forwarder (`dsh plugin --profile <name> add <pkg>`).
The image is set up so installs work with no extra steps:

- **pnpm is bundled** (required by `dsh plugin` and the `dshmarket` community
  market) and its global config bakes in `dangerouslyAllowAllBuilds: true` —
  dependency build scripts (prebuilt downloads and `node-gyp` compiles) run
  without interactive approval;
- a **C/native toolchain** (`gcc`, `g++`, `make`, `python3`, `pkg-config`)
  is in the runtime so plugins that compile native addons build even when no
  prebuilt binary matches;
- pnpm's **content store lives on the `$DSH_HOME` volume** (`.pnpm-store`), so
  installs are fast and survive container recreation.

```sh
# on the host:
docker run --rm -it \
  -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace \
  ghcr.io/andreasseidl/dsh-docker:latest plugin --profile web add dshmarket
# or from inside the container (dsh is on PATH):
docker exec -it dsh dsh plugin --profile web add <package>
```

Installed plugins persist on `$DSH_HOME` and, once the profile reloads, appear
in the web UI's plugin list.

Note the profile's bundle registry: the harness treats *server* plugins (packages
that declare a `dsh.bundle` manifest field) as profile layers and registers
them into `dsh.profile.bundles` automatically. A package that only declares
`dsh.bundle` when it is ready (e.g. some pre-1.0 community RCs) is installed
as a plain profile dependency — the CLI even prints
`declares no dsh.bundle — installed as a plain dependency, not a profile layer`
for those. To make a plain dependency load as a bundle, add its package name to
`dsh.profile.bundles` in `$DSH_HOME/profiles/web/package.json` (a manual step,
not something a pnpm forwarder can do for you).

### Other `dsh` modes

The container is a full `dsh` launcher, so every CLI mode works. Each example
mounts both the harness-home and the workspace volumes:

| Command | Container |
|---|---|
| Web GUI | default (`web`, faithful loopback) |
| One-shot task | `docker run --rm -it -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace ghcr.io/andreasseidl/dsh-docker:latest --profile headless "run the tests"` |
| Inspect the composed profile | `docker run --rm -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace ghcr.io/andreasseidl/dsh-docker:latest --profile web --dump-default-config` |
| Install a plugin into a profile | `docker run --rm -it -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace ghcr.io/andreasseidl/dsh-docker:latest plugin --profile web add <package>` |
| Edit your patch layer | edit `profiles/web/cordis.patch.yml` on the volume — it hot-reloads |

The default agent preset is `standard`; its codex/claude delegation tool rows
are mounted but their CLI binaries are **not** shipped by default (that saves
~560 MB — `/openai/codex` & `claude-agent-sdk` platform packages are only
resolved when the model actually invokes `subagent_codex`/`subagent_claude_code`).

### Building your own image from source

You normally don't need this — the published image is the supported way to run
it. If you want to build from a harness checkout (e.g. to test an unreleased
version or with different binaries bundled):

```sh
# Build from a deepseek-harness checkout, then run or publish:
make build DSH_SRC=/path/to/deepseek-harness          # dsh:dev
make build TAG=0.1.0                                  # dsh:0.1.0
make publish TAG=0.1.0 REGISTRY=ghcr.io/you           # docker push ghcr.io/you/dsh:0.1.0
docker run --rm -it -v dsh-home:/home/dsh/.dsh ghcr.io/you/dsh:0.1.0 --profile headless "run the tests"

# bundle the codex/claude CLI binaries (+~560 MB) so subagent_delegation rows resolve:
make build TAG=edge INCLUDE_AGENT_CLIS=1
# or drop the C/native toolchain for a leaner image (plugin installs needing a compiler fail):
make build INCLUDE_BUILD_TOOLS=0
```

`make publish`/`make push` just runs `docker push` — log in with
`docker login` first. The tag name is passed through verbatim, so
`REGISTRY=ghcr.io/you IMAGE=dsh TAG=v1` → `ghcr.io/you/dsh:v1`.

## Size

Measured for the default build (no agent CLIs), `linux/amd64`, as the
gzip'd `docker save` payload (the "compressed" size you actually transfer):

- **Default: ~1.5 GB uncompressed / ~298 MiB (~312 MB) compressed** — the
  C/native toolchain (gcc g++ make python3 pkg-config) is baked in so
  `dsh plugin add` can compile native addons at runtime when no prebuilt
  binary matches (the default; see the C-toolchain note below). The runtime
  image drops `*.map` sourcemaps — the largest build-time-only artifact
  (~20 MB; used only for in-image source-mapped debugging, which the runtime
  never consumes and which leaves stack-trace text unchanged) — while keeping
  the original package `src/**` TypeScript as readable in-image
  reference/audit trail.
- `make build INCLUDE_BUILD_TOOLS=0` drops the compiler/python3 set for a
  leaner **~1.1 GB uncompressed / ~211 MiB (~221 MB)** image; plugin installs
  that need a compiler will then fail.

The toolchain is kept by default because "plugin installs work for anything"
beats ~100 MB of compressed size; the harness's own native addons (node-pty,
sharp, koffi) are compiled once at image build and need no toolchain at
runtime, but third-party plugins with no prebuilt native binary do.

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

## For maintainers & contributors

Everything above is about **using** the container. The development and
contribution depth lives in separate files so this page stays focused on
deployment, setup, and use — and so tools/agents can find each topic fast:

- **[DEVELOPMENT.md](DEVELOPMENT.md)** — repository layout, Makefile reference,
  how the image is built (multi-stage build), build-speed measurements, and
  cache hygiene.
- **[TESTING.md](TESTING.md)** — the smoke, plugin-install, hardened-compose,
  and plugin-suite verifiers; how to run them against your built image.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — contribution workflow and the CI /
  publishing mechanics (release tags, weekly `nightly`, native multi-arch
  builds, GHCR cache).

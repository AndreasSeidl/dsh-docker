# DeepSeek Harness in Docker

Run the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
coding-agent GUI with one command. No build, no Node.js, no `pnpm` — just
Docker and a browser.

```sh
docker run -d --name dsh -p 127.0.0.1:3080:3080 \
  -v dsh-home:/home/dsh/.dsh \
  -v dsh-workspace:/workspace \
  ghcr.io/andreasseidl/dsh-docker:latest
```

Then read the access URL from the log and open it exactly as printed — the GUI
is session-locked and the address carries a one-time token (see
[First run](#first-run--the-session-locked-url)). Add your API key on the
Settings page and you're in.

> Out of the box only **this machine** can use the GUI. One variable opens it
> to the rest of your network — there is no login screen yet, so see
> [Network access](#network-access) first.

---

## First run — the session-locked URL

The harness locks the GUI behind a per-run session token (only someone who can
read the container log can get in). On every boot the proxy prints a ready line
starting with `dsh web:` in the log that carries that token:

```sh
docker logs dsh | grep 'dsh web:'
# dsh web: http://localhost:3080/?token=OQMr0P5kk46m1tw8S3g8FTj4io0fso8Cn9UaIEXA
```

Open **that exact URL**. Your browser trades the token for a session cookie
(valid up to 30 days), so afterwards plain <http://localhost:3080> works too —
until the container is recreated, at which point the token changes and you pick
the new `dsh web:` URL from the log again. Requesting a URL without a valid
token or cookie gets a `401 … reopen the URL printed by dsh web` message.

With Compose the same line is in `docker compose logs dsh`. Set
`-e DSH_WEB_PORT=<port>` (or `DSH_WEB_PORT` in your `.env`) to match the host
port you publish, so the printed URL points at the right place.

---

## Quick start

### Option A — `docker run`

```sh
docker run -d --name dsh -p 127.0.0.1:3080:3080 \
  -e DEEPSEEK_API_KEY=sk-... \
  -e DSH_WEB_PORT=3080 \
  -v dsh-home:/home/dsh/.dsh \
  -v dsh-workspace:/workspace \
  ghcr.io/andreasseidl/dsh-docker:latest
```

Then open the tokenized access URL from the log —
`docker logs dsh | grep 'dsh web:'` — see [First run](#first-run--the-session-locked-url).
The `DEEPSEEK_API_KEY` line is optional — you can enter the key in the GUI
instead, and the `DSH_WEB_PORT` line just tells the container which host port
you chose so the printed URL is right (default 3080).

The GUI is served on **3080** inside the container — the same port the
harness's own documentation uses, so anything written for upstream applies here
unchanged. Map it wherever you like on the host: `-p 127.0.0.1:9000:3080` puts
it on <http://localhost:9000> (and pass `-e DSH_WEB_PORT=9000` so the printed
access URL points at <http://localhost:9000>).

The `127.0.0.1:` prefix is what keeps the GUI to this machine; drop it
(`-p 3080:3080`) to open it to your network, and read
[Network access](#network-access) first.

### Option B — Docker Compose (recommended)

In an empty folder:

```sh
curl -O https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/.env.example
cp .env.example .env        # optional — put your API key in it
docker compose up -d
```

Open the access URL from the log — `docker compose logs dsh | grep 'dsh web:'`
(see [First run](#first-run--the-session-locked-url)). Compose gives you
restart-on-reboot, a hardened sandbox (read-only root filesystem, no
capabilities, no privilege escalation), and every setting in one `.env` file.

Stop with `docker compose down` — your data is kept. `docker compose down -v`
deletes the volumes and everything on them.

---

## Work on your own code

By default the agent works in a private Docker volume. To point it at a real
project, mount that folder as the workspace:

```sh
docker run -d --name dsh -p 127.0.0.1:3080:3080 \
  -v dsh-home:/home/dsh/.dsh \
  -v "$PWD":/workspace \
  ghcr.io/andreasseidl/dsh-docker:latest
```

With Compose, set it in `.env`:

```sh
DSH_WORKSPACE_DIR=./my-project
```

The agent can only see what you mount — the rest of your machine is invisible
to it.

**If the agent can read your files but cannot save changes**, the folder
belongs to a different user than the one inside the container (uid `999`). The
container tells you so at startup with the exact command to run; it is:

```sh
sudo chown -R 999:999 ./my-project     # give the container user ownership
# or, if you would rather not change owners:
chmod -R a+rwX ./my-project
```

(On macOS and Windows with Docker Desktop this does not come up — file sharing
already maps ownership for you.)

---

## Settings you might actually change

All of these are environment variables. With Compose, put them in `.env`
(copy [.env.example](.env.example)); with `docker run`, pass them as `-e NAME=value`.

| Variable | Default | What it does |
|---|---|---|
| `DEEPSEEK_API_KEY` | — | Your provider key. Optional — you can enter it in the GUI instead. |
| `DEEPSEEK_BASE_URL` | — | Point at a compatible endpoint instead of api.deepseek.com. |
| `DSH_WEB_PORT` | `3080` | The port on **your** machine — it is what the startup banner prints. With Compose it also sets the `-p` mapping. With `docker run` you choose it in `-p <port>:3080`; add `-e DSH_WEB_PORT=<port>` so the banner matches. |
| `DSH_BIND_ADDRESS` | `127.0.0.1` | *(Compose only)* The address the GUI is published on. The default means this machine only; **set it to `0.0.0.0` for LAN access**. |
| `DSH_WORKSPACE_DIR` | volume | *(Compose only)* Host folder the agent works in, e.g. `./my-project`. |
| `DSH_TAG` | `latest` | *(Compose only)* Image version: `latest`, `nightly`, or a pinned release. |
| `DSH_TELEMETRY_DISABLED` | — | Any non-empty value opts out of harness telemetry. |
| `DSH_QUIET` | — | Silences the container's startup banner. |

Changing which port you open takes one variable:

```sh
DSH_WEB_PORT=9000 docker compose up -d      # → http://localhost:9000
```

Everything else the harness understands (provider keys, `HTTP_PROXY`, `TZ`,
`NODE_OPTIONS`, …) passes straight through as a normal environment variable.
See [all variables](#all-environment-variables) for the complete list.

---

## Everyday commands

| I want to… | Command |
|---|---|
| see what it's doing | `docker logs -f dsh` |
| get the access URL (session token) | `docker logs dsh \| grep 'dsh web:'` |
| stop it (keeping data) | `docker stop dsh` / `docker compose down` |
| start it again | `docker start dsh` / `docker compose up -d` |
| update to the newest image | `docker compose pull && docker compose up -d` |
| get a shell inside | `docker exec -it dsh bash` |
| install a plugin | `docker exec -it dsh dsh plugin --profile web add <package>` |
| run a one-shot task | `docker exec -it dsh dsh --profile headless "run the tests"` |
| see container usage help | `docker run --rm ghcr.io/andreasseidl/dsh-docker:latest container-help` |
| back up my data | `docker run --rm -v dsh-home:/data -v "$PWD":/out alpine tar czf /out/dsh-backup.tgz -C /data .` |
| start completely fresh | `docker compose down -v` (⚠️ deletes settings, history, and workspace) |

---

## Troubleshooting

**Port 3080 is already in use.** Pick another host port: `DSH_WEB_PORT=9000
docker compose up -d`, or `-p 9000:3080` with `docker run`.

**The agent can't save files.** See
[Work on your own code](#work-on-your-own-code) — it's a folder-ownership
mismatch, and the startup banner prints the exact fix.

**"No model credentials found yet."** Set `DEEPSEEK_API_KEY`, or open the GUI's
Settings page and enter your key there — it is saved on the `dsh-home` volume
and reused on every restart.

**My settings/history disappeared.** You ran without the `dsh-home` volume. The
startup banner warns about this; add `-v dsh-home:/home/dsh/.dsh`.

**Connection refused from another machine.** That's the default: the port is
published on `127.0.0.1` only. See [Network access](#network-access) to open it
up — and read the warning there first.

**Check the container's own view of things:** `docker logs dsh` — the startup
banner reports the URL (using `DSH_WEB_PORT`), both data locations, whether they
are persistent, and whether credentials are configured.

---

## Network access

**By default nothing on your network can reach the GUI.** The port is published
on `127.0.0.1`, so the kernel only ever accepts connections from the machine
running Docker — a browser anywhere else doesn't get refused, it doesn't get a
connection at all.

**For LAN access, set `DSH_BIND_ADDRESS` to `0.0.0.0`** — that is the only
value that opens it up, and it is a literal address, not an on/off flag:

```sh
DSH_BIND_ADDRESS=0.0.0.0 docker compose up -d
```

Or put `DSH_BIND_ADDRESS=0.0.0.0` in your `.env`. With `docker run` there is no
variable — the same thing is done by dropping the `127.0.0.1:` prefix from the
port mapping:

```sh
docker run -p 3080:3080 ...        # instead of -p 127.0.0.1:3080:3080
```

There is **no user-facing login** — the only gate is a per-boot session token.
The harness prints a tokenized ready URL (`dsh web: …?token=…`) in the
container log, and requests without that token or its cookie get a `401`. The
token and the cookie it trades for are effectively a single shared secret
readable from the host (`docker logs dsh`): anyone who obtains it can use the
agent, read your workspace, and run commands in the container. Only expose the
port on a network you trust, and treat the token like a password for that
container.

**The session token works identically over LAN** — nothing about it is bound to
a host name or IP. The proxy always presents the fixed loopback authority to
the app (whatever `Host` a client sends is rewritten to `127.0.0.1:30800`), so
the token exchange and the resulting cookie validate from any machine that can
reach the published port:

- On the Docker host, the printed `dsh web:` URL is clickable as-is. A LAN
  client has to replace `localhost` with the host machine's address, e.g.
  <http://192.168.1.5:3080/?token=…> (the token is a query string, so the
  substitution is all that changes).
- The cookie lasts up to 30 days and is not tied to the machine that first
  exchanged it — anyone who gets the token or extracts the cookie can access
  from anywhere the port is reachable, until the container is recreated.
- The cookie carries **no `Secure` flag** and plain-HTTP LAN transmits it in
  cleartext, so someone sniffing the LAN can capture and reuse a session. Put
  TLS in front for anything beyond a trusted home/office network.

In particular there is still **no Host-header allow-list**: any client can claim
any `Host` header, so such a check adds no real protection. The publish address
is what keeps the port private, and the log token — not the `Host` header — is
what gates access once it is published.

**Why an address and not `DSH_LAN=1`?** Compose can only test whether a
variable is *set*, never what it holds. An on/off switch would therefore have
to treat "unset" as "publish on every interface" — making the wide-open state
the default for anyone who downloads the compose file and runs it. An address
lets "unset" mean `127.0.0.1`, so the safe state is the one you get by doing
nothing. `DSH_BIND_ADDRESS=1` stops at startup with `invalid IP address: 1`;
the two values you want are `127.0.0.1` and `0.0.0.0`.

<details>
<summary><b>How it works — the bundled reverse proxy</b></summary>

The harness deliberately **refuses to bind `dsh web` to `0.0.0.0`** (its `/api`
trust fence assumes loopback or explicitly trusted authorities), and its
frontend calls `crypto.randomUUID()`, which browsers only expose in *secure
contexts* (https or localhost). A plain-HTTP LAN deployment therefore needs two
fixes, both of which this image supplies without forking the harness:

- **[`container/scripts/reverse-proxy.mjs`](container/scripts/reverse-proxy.mjs)**
  (zero dependencies) listens on `3080` and forwards to the loopback-only app on
  `30800`, rewriting `Host` and `Origin` to loopback so the `/api` fence sees a
  local request and the browser sees one same-origin page. WebSocket upgrades
  (`/api/events.*`) are transported the same way.
- A tiny `crypto.randomUUID` polyfill is injected into the served `index.html`
  at image build time (container-only; the harness source is untouched).

The proxy is deliberately **not** an auth layer — it is the documented place to
add one. It is always in front of the app, so `dsh web` itself always runs
untouched on its own loopback-only port.

</details>

---

## Reference

<details>
<summary><b>All environment variables</b></summary>

### Web server

| Variable | Default | Maps to | Notes |
|---|---|---|---|
| `DSH_WEB_PORT` | `3080` | banner/display only | The host port you publish the GUI on, used by the startup banner. Inside the container the GUI is always on `3080`. |
| `DSH_WEB_NO_OPEN` | `1` | `dsh web --no-open` | Containers have no browser; set `0` to allow the browser-handoff path. |
| `DSH_WEB_ARGS` | — | raw extra args | Must start with `-`; passed through to `dsh web` for exotic flags. |
| `DSH_WORKSPACE` | `/workspace` | process cwd (default workspace) | The in-container path; back it with a volume. |
| `DSH_HOME` | `/home/dsh/.dsh` | harness home | Point at a directory inside your volume if you prefer a dedicated layout. |
| `DSH_QUIET` | — | container banner | Non-empty silences the startup summary. |

The two in-container ports are **fixed and not configurable**: the proxy serves
the GUI on `3080` (the port upstream documents, so every `localhost:3080` in the
harness's docs works as written), and `dsh web` itself
runs behind it on `127.0.0.1:30800` — high enough to stay clear of the dev
servers the agent starts inside the container, and below the ephemeral range.
The only port worth choosing is the host one you publish. `localhost`,
`127.0.0.1` and any `127.x` Host header are trusted by the `/api` fence
automatically.

### Harness & providers (pass straight through)

- `DSH_TELEMETRY_DISABLED` — opt out of telemetry (any non-empty value).
- `DSH_TOOLS_MODE` — `native` / `code` / `both` tool presentation.
- `DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL` — the shipped DeepSeek adapter
  (credentials can equally live in `.credentials.yaml` on the volume).
- Any pi-ai provider keys referenced from `settings.yaml` (e.g. `DGX_API_KEY`).
- `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`, `TZ`, `NODE_OPTIONS`, and every
  other variable the layered `.env` loader forwards.

</details>

<details>
<summary><b>Volumes &amp; what is stored where</b></summary>

The container uses two mounted paths. **Both matter**: the harness is
self-modifying by design, and without volumes everything you do is lost the
moment the container is removed. The startup banner warns you when one is
missing.

| Path in container | What it is | Back it with |
|---|---|---|
| `/home/dsh/.dsh` | the harness home (`$DSH_HOME`): **all** persistent harness data | a named volume (`dsh-home`) or a host directory |
| `/workspace` | the agent's **workspace** — the directory it reads and edits files in | a named volume (`dsh-workspace`) or a host bind mount of real code |

```
/home/dsh/.dsh/
├── profiles/            # per-profile dirs: package.json, cordis.patch.yml (YOUR patch layer, hot-reloaded)
│   ├── node_modules/    # launcher-maintained flat plugin links (re-healed at every boot)
│   └── web/             # the auto-initialized web profile
├── .pnpm-store/         # pnpm content store for `dsh plugin add` (persists installs)
├── settings.yaml        # seeded on first boot; model selection, UI preferences
├── AGENTS.md            # seeded on first boot; your user-global instruction file
├── .credentials.yaml    # provider credentials
├── sessions/            # conversation history
├── storages/            # persisted storage domains
└── .agent-presets/      # agent presets you author
```

On first boot the image seeds an empty `$DSH_HOME` with a scaffold
`settings.yaml` (empty, so stock defaults apply) and `AGENTS.md` (the
user-global briefing the agent loads before every session), then
auto-initializes the `web` profile. Existing files are never overwritten.

Inside the container the `dsh` user owns `/workspace`, `/home/dsh`, and the
install at `/app`. Everything else is reachable only through volumes you mount,
so the agent can never touch host files outside them. With Compose the root
filesystem is additionally read-only.

</details>

<details>
<summary><b>Picking a tag</b></summary>

- **`:latest`** — the latest *published release*. What you want to try it out.
- **`:<version>`** — a pinned release, e.g. `0.1.1-rc.2`. Pin this in production.
- **`:nightly`** — a weekly rebuild of the harness's default branch.

New upstream releases are picked up automatically: the container repo polls
for upstream `dsh-v*` releases every hour and, when a newer one exists, builds
and publishes both architectures under its version plus `:latest` — no manual
tag push needed. With a pinned `:<version>` you stay on exactly that release
until you choose to bump it.

```sh
DSH_TAG=0.1.1-rc.2 docker compose up -d
```

</details>

<details>
<summary><b>Plugins</b></summary>

`dsh plugin` is a thin pnpm forwarder. The image is set up so installs work
with no extra steps: pnpm is bundled with `dangerouslyAllowAllBuilds: true`
(so postinstall hooks and `node-gyp` compiles run unattended), a C/native
toolchain (`gcc`, `g++`, `make`, `python3`, `pkg-config`) is in the runtime, and
pnpm's content store lives on the `$DSH_HOME` volume so installs are fast and
survive container recreation.

```sh
docker exec -it dsh dsh plugin --profile web add <package>
```

Installed plugins persist on `$DSH_HOME` and appear in the web UI's plugin list
once the profile reloads.

Note the profile's bundle registry: the harness treats *server* plugins
(packages that declare a `dsh.bundle` manifest field) as profile layers and
registers them into `dsh.profile.bundles` automatically. A package that doesn't
declare `dsh.bundle` is installed as a plain profile dependency — the CLI even
prints `declares no dsh.bundle — installed as a plain dependency, not a profile
layer`. To make such a dependency load as a bundle, add its package name to
`dsh.profile.bundles` in `$DSH_HOME/profiles/web/package.json`.

</details>

<details>
<summary><b>Other <code>dsh</code> modes</b></summary>

The container is a full `dsh` launcher: the first argument selects the mode,
and anything that isn't a container convenience mode is passed straight to the
CLI.

| Mode | Command |
|---|---|
| Web GUI (default) | `docker run ... IMAGE` |
| Interactive shell | `docker run --rm -it ... IMAGE shell` |
| Container usage help | `docker run --rm IMAGE container-help` |
| One-shot task | `docker run --rm -it ... IMAGE --profile headless "run the tests"` |
| Inspect the composed profile | `docker run --rm ... IMAGE --profile web --dump-default-config` |
| Install a plugin | `docker run --rm -it ... IMAGE plugin --profile web add <package>` |
| Edit your patch layer | edit `profiles/web/cordis.patch.yml` on the volume — it hot-reloads |

(`...` = the two `-v` volume flags; the web row also wants
`-p 127.0.0.1:3080:3080`.)

The default agent preset is `standard`; its codex/claude delegation tool rows
are mounted but their CLI binaries are **not** shipped by default (that saves
~560 MB — they are only resolved when the model actually invokes
`subagent_codex` / `subagent_claude_code`).

</details>

<details>
<summary><b>Image size</b></summary>

Measured for the default build (no agent CLIs), `linux/amd64`, as the gzip'd
`docker save` payload:

- **Default: ~1.5 GB uncompressed / ~298 MiB compressed.** Includes the
  C/native toolchain so `dsh plugin add` can compile native addons at runtime.
  Sourcemaps (`*.map`, ~20 MB) are dropped; the packages' `src/**` TypeScript is
  kept as an in-image reference/audit trail.
- `make build INCLUDE_BUILD_TOOLS=0` drops the compiler set for a leaner
  **~1.1 GB uncompressed / ~211 MiB compressed** image; plugin installs that
  need a compiler will then fail.

The toolchain is kept by default because "plugin installs work for anything"
beats ~100 MB of compressed size.

</details>

<details>
<summary><b>Known limitations</b></summary>

- **Auth**: a per-boot session token printed in the container log is the whole
  gate — there are no user accounts. Its 30-day cookie is not bound to any
  machine and travels in plaintext over plain-HTTP LAN, so expose beyond a
  trusted network only with TLS in front or real auth there. There is no
  Host-header allow-list either — any client can claim any `Host`, so one would
  not add protection.
- **Codex/Claude delegation** without `INCLUDE_AGENT_CLIS=1` follows the
  upstream model: the tool rows mount, and a call fails with a missing-binary
  error (same as running `dsh web` on a machine without those CLIs).
- **Host-bound workspaces**: a bind-mounted `/workspace` owned by a different
  uid can make `git` warn about "dubious ownership"; use
  `git -c safe.directory=/workspace ...` (with Compose, `$HOME` is read-only, so
  `git config --global` won't stick).
- The macOS/Windows-only surfaces (PowerShell, native directory picker) are
  inert on Linux; `--no-open` is host-agnostic, so web mode behaves the same on
  Docker Desktop hosts.
- The landlock sandbox binary is not shipped (it needs built-in kernel
  support); the sandbox stack degrades to its environment-defined fallback as it
  does on any unsupported host.
- Custom agent presets you author belong in `$DSH_HOME/.agent-presets/` on the
  volume (they carry the same trust as shell access — upstream's own rule).

</details>

---

## Building it yourself

You normally don't need this — the published image is the supported way to run
it. To build from a harness checkout (e.g. to test an unreleased version):

```sh
make build DSH_SRC=/path/to/deepseek-harness    # → dsh:dev
DSH_IMAGE=dsh:dev docker compose up -d          # run your build
```

`make help` lists every target. Deeper documentation lives in separate files so
this page stays about *using* the container:

- **[DEVELOPMENT.md](DEVELOPMENT.md)** — repository layout, Makefile reference,
  how the image is built, build-speed measurements, cache hygiene.
- **[TESTING.md](TESTING.md)** — the smoke, plugin-install, hardened-compose and
  plugin-suite verifiers.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — contribution workflow, CI and
  publishing mechanics.

## License

[MIT](LICENSE).

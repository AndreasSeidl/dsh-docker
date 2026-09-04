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

## Install — one line, or the manual Docker way

There are two ways to get it running:

- **The one-liner installs without any modification.** It downloads the Compose
  files into `~/.dsh-container` (override with `DSH_CONTAINER_DIR`) and runs
  that exact stack — zero configuration, safe defaults:

```sh
# Local mode — this machine only; ~/.dsh for harness data, the folder you're
# in as the workspace. (Running the one-liner with no arguments does this too.)
curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \
  | sh -s -- local

# Server mode — persistent volumes + LAN access by default (see Server mode)
curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \
  | sh -s -- server
```

- **The manual Docker way is for when you want to modify what actually
  happens** — clone the repo (or just fetch the Compose files) and run
  `docker compose` / `docker run` yourself, editing as you go. The installer
  deliberately does **not** reuse files from a checkout: even when you run it
  from a clone, it downloads its own copy into `~/.dsh-container`, so your
  directory (the LOCAL workspace) is never tangled up with the installer's
  settings. Manual steps are under [Quick start](#quick-start) and
  [Server mode](#server-mode) below — Compose files are `docker-compose.yml`
  (local) and `docker-compose.server.yml` (server).

---

## Two ways to run it

Everything is one Docker image; what differs is how the harness data and the
workspaces are stored, and who can reach the GUI. There is an installer for
each:

| | **Local mode** (`install.sh local`) | **Server mode** (`install.sh server`) |
|---|---|---|
| What it's for | You, on this machine, running the GUI in Docker | A machine on your network that you reach from somewhere else |
| Harness data (settings, credentials, history) | A **host directory** (default `~/.dsh` — shared with a native `dsh` install if you have one) | A **named volume** (`dsh-server-home`) |
| Workspaces | A **host directory** (default the folder you run the installer from) | A **named volume** (`dsh-server-workspaces`) holding one directory per workspace, created in the GUI |
| Published on | `127.0.0.1` — **this machine only** | `0.0.0.0` — **LAN by default** |
| Compose file | `docker-compose.yml` | `docker-compose.server.yml` |

`install.sh local` / `install.sh server` here just abbreviate the one-liner in
the [Install](#install--one-line-or-the-manual-docker-way) section — the
installer always downloads its own project files into `~/.dsh-container` and
runs from there, whichever form you type.

Both run the same hardened container (read-only root filesystem, no
capabilities, no privilege escalation). The GUI is always the same
[session-locked web app](#first-run--the-session-locked-url); the differences
are where your data lives and which interfaces accept connections.

- **Local mode** is below under [Quick start](#quick-start).
- **Server mode** and how workspace selection works there is its own section:
  [Server mode](#server-mode).

Both are on the published image, so there is no build step. `make install-local`
and `make install-server` are aliases for the installer; `make help` lists them.

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

## Skip the session token (trust the layer in front)

Once a **real access layer** stands in front of the GUI, the per-run token is
redundant — its only job is gating "anyone who can reach the port". If that
layer is a genuine boundary (a TLS + Basic Auth reverse proxy, a VPN, or plain
loopback), you can drop the token entirely so clients get a clean, stable URL
with no 401/token dance:

```sh
DSH_WEB_AUTH_MODE=trust-proxy
```

In this mode the bundled reverse proxy does the token exchange itself (once at
boot, again if a 30-day cookie ever expires) and replays the session cookie on
every request — the printed `dsh web:` line carries no `?token=`, and any
browser that can reach the proxy is in. That is the point: **the thing in front
is the access control now**. If that layer speaks TLS, set `DSH_PUBLIC_URL` to
the HTTPS origin clients actually use, so the printed URL and redirects are
honest.

Remember: **LAN access is by definition insecure**. A plain publish on your LAN
has no login — only the per-boot token — and any machine on that network is a
potential attacker. `trust-proxy` is only safe because the real boundary sits
in front; on a plain `0.0.0.0` publish (no such layer) it hands the GUI to
anyone who can reach the port. The default `token` keeps the lock, so prefer
leaving it unless you know what is in front.

---

## Supported versions

The minimum upstream harness version this repo guarantees support for lives in
[`.supported-version`](.supported-version) (the "supported version floor") —
defined as *the oldest version that still passes the complete test suite*. It
drives the test suites and the publish pipeline (see
[CONTRIBUTING.md](CONTRIBUTING.md)):

- an image **at or above the floor must pass every current check** — the
  suites assert the full contract, with no version-conditional fallbacks;
- an image **below the floor is unsupported**: the test suites do **not run
  against it** at all, and the publish pipeline refuses to publish it. It may
  remain on GHCR as an immutable artifact, but nothing is guaranteed about it.

The floor stated below is generated from [`.supported-version`](.supported-version)
(edit the file, not this paragraph — the `main-check` workflow
re-states it automatically on every push; `make docs-sync` does the same
locally).

Right now the floor is **`0.1.2-alpha.2`** — the oldest version that still
passes the complete test suite. The current release is **`0.1.2-alpha.3`**
(alias of `latest`). The two versions below the floor, `0.1.1-rc.2` and
`0.1.2-alpha.1`, are unsupported (kept on GHCR, no longer tested):

| Version | Session lock / WS relay | Trust-proxy | Server-mode profile | Docker health |
|---|---|---|---|---|
| `0.1.1-rc.2` | no (open 200 first boot) | no | no | `healthy` |
| `0.1.2-alpha.1` | yes | no | no | **reports `unhealthy`** ⚠️ |
| `0.1.2-alpha.2` | yes | yes | yes | `healthy` |
| `0.1.2-alpha.3` (`latest`) | yes | yes | yes | `healthy` |

The one operational caveat: `0.1.2-alpha.1` **always reports `unhealthy` under
Docker even though it boots and serves correctly** — its baked-in healthcheck
was written before the 0.1.2+ session lock made an unauthenticated probe answer
`401` (which `curl -f` treats as failure). Orchestrators that restart on
"unhealthy" would therefore bounce it; prefer `0.1.2-alpha.2` or later.

---

## Quick start (Local mode)

This runs the GUI on **this machine only**. The scripts below are what
**Local mode** means; the same image is also used for [Server mode](#server-mode).

Fastest path (downloads its own Compose files and writes the `.env` for you —
harness data in `~/.dsh`, the agent works in the current directory, GUI on
`127.0.0.1`):

```sh
curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh | sh -s -- local
```

Or one of the manual routes:

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

## Server mode

For a machine that runs persistently and is **reached from somewhere else** — a
home server, a VPS, an office box. The harness data and the workspaces both
live on **named volumes** (so they survive container recreation and reboots),
and the GUI is **published on every interface by default** (`0.0.0.0`), because
the whole point is remote access.

```sh
curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh | sh -s -- server
# → downloads the Compose files, creates .env.server (add your API key there),
#   starts the stack, and tells you how to find the access URL
```

`docker-compose.server.yml` sets up one container (`dsh-server`) with two
volumes and nothing else writable on the container's filesystem:

| Mount in container | Volume | What lives there |
|---|---|---|
| `/home/dsh/.dsh` | `dsh-server-home` | everything persistent about the harness: `settings.yaml`, credentials, sessions/chat history, **the workspace registry** (which workspaces exist, renames, archives), plugins |
| `/workspaces` | `dsh-server-workspaces` | the workspace **file trees** — one directory per workspace |

### Workspace selection works over the wire

You asked how the file browser behaves when the browser is somewhere else — the
short answer is it already works, because the picker used in this image is not
an OS dialog at all:

- The harness has a *directory-picker* seam with three backends
  (`-native` opens an OS chooser on the server's display, `-browse` is an
  **in-app file browser**, and `-auto` picks one at boot). The container is
  headless, so anything usable here is server-rendered HTTP: list a directory,
  type a path, create a folder.
- **Server mode pins `-browse` explicitly** via a `cordis.patch.yml` seeded
  into the harness home on first boot. That makes the "Select Workspace
  Directory" dialog a normal web dialog: it lists the server's `/workspaces`,
  lets you type a full path or browse, and lets you create a folder — nothing
  needs a display or a native helper, so a browser anywhere on the network can
  use it. (A native dialog would be wrong here: it would try to open on the
  server's own screen.)
- The bootstrap also symlinks `/workspaces` into the home directory the dialog
  starts in, so remote users land on the workspace root instead of having to
  navigate to `/` first.

So the [workspace-management workflow](#everyday-commands) — `Add workspace`,
create a folder, rename, archive — is the same in-app flow whether you're on
the same machine or on the network.

### The workspace model

Every workspace is **one subdirectory of `/workspaces`** (for example
`/workspaces/acme-app`), created from the GUI and persisted on the
`dsh-server-workspaces` volume. Opening a workspace starts a session whose
working directory is that folder, and the harness's file sandbox
(`workspace-write`, the web profile's default) confines each session's writes
to **its own workspace** — so workspaces on one server do not share write
access.

The **workspace registry** (names, order, archives, which sessions belong to
which workspace) and the **chat history** persist on the other volume
(`dsh-server-home`), separate from the files. Backing up both volumes backs up
the whole server.

### Access, security, and the log

- The GUI is offered on the network by default. There is **no login screen** —
  this is the single most important fact about server mode.
- The GUI is locked behind a **per-run session token** (this image family and
  every newer harness build): the log's `dsh web:` line carries a fresh
  `?token=...` (rotates each start), and until a browser exchanges it, `/` and
  `/api` answer `401`. The exchange is a `303 + Set-Cookie`: the browser trades
  the token once for a signed cookie (30 days, `HttpOnly`, `SameSite=Strict`).
  On a remote client, replace `localhost` with the server's address
  (`http://192.168.1.50:3080/?token=...`).
- The token and the cookie are effectively a **shared password**: anyone who can
  read the container log (or capture the token/cookie) can drive this agent and
  read every workspace. The signing secret persists on the home volume, so a
  container restart invalidates the *printed token* but not cookies already
  issued — existing browsers keep working; only first-time joiners need the new
  token. There is no per-user model and no way to revoke a cookie short of
  resetting that volume.
- The **publish address is the real boundary**: `0.0.0.0` means the port accepts
  connections from anywhere that can reach this host. The token and cookie cross
  the network **in cleartext on plain HTTP**, so a sniffer on the LAN can lift
  either and replay it. Treat the log like a password store, publish on a
  network you trust, and put **TLS / a reverse-proxy auth layer in front**
  (Authelia, basic auth, a VPN) before exposing it beyond that — the bundled
  proxy is the documented insertion point for exactly that.
- **Make the token URL clickable from another machine**: without help, the
  container prints the token URL as `http://localhost:3080/?token=...`, and a
  remote user who opens it unchanged ends up on *their own* localhost. Set
  `DSH_PUBLIC_URL` (e.g. `http://192.168.1.50:3080`, or `https://harness.example`
  once TLS is in front) in `.env.server` and the printed URL carries that
  origin — nothing to hand-edit. The proxy also sends `Referrer-Policy:
  no-referrer` on every page, so the token never leaks through the `Referer`
  header the page would otherwise send to third-party resources.
- Defaults: `DSH_BIND_ADDRESS` is `0.0.0.0` here (set it to `127.0.0.1` to lock
  it back to the server itself), and `DSH_WEB_PORT` is `3080`.

### Remote browser Settings

DeepSeek Harness serves its **Settings pages** (the Models/provider-directory
tab and the General `settings.yaml` editor) only to a browser whose page is on
a **loopback** host. A remote browser — which is what server mode is for —
gets *"Loading the provider directory failed: settings are unavailable in this
browser"*, because upstream deliberately keeps provider credentials tied to the
machine that owns the harness.

This image patches the shipped client so Settings also honor
`DSH_ALLOW_REMOTE_SETTINGS`, and **defaults it to `1` in server mode**: a remote
browser can then read and edit the Settings pages (saved to the
`dsh-server-home` volume, so they survive restarts and apply to every client).
The tradeoff is the one this section already states — anyone who can open the
remote GUI can also manage provider keys — which in server mode is exactly the
access gate described above (the publish mapping + token/cookie, and ideally a
TLS/edge layer in front). To keep upstream's loopback-only behavior, set:

```sh
DSH_ALLOW_REMOTE_SETTINGS=0
```

in `.env.server` (or `-e`). Outside server mode the flag is off by default, so
local/loopback deployments behave exactly like upstream.

### Everyday server commands

| I want to… | Command |
|---|---|
| see the access URL | `docker compose -f docker-compose.server.yml logs dsh-server \| grep 'dsh web:'` |
| add your provider key | edit `.env.server`, then `docker compose -f docker-compose.server.yml --env-file .env.server up -d` |
| stop (data kept) | `docker compose -f docker-compose.server.yml down` |
| fresh slate (⚠️ deletes everything) | `docker compose -f docker-compose.server.yml down -v` |
| update the image | `curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \| sh -s -- update server` |
| shell inside | `docker exec -it dsh-server bash` |

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

All of these are environment variables. With the one-liner they are written for
you into `~/.dsh-container/.env` (local) / `.env.server` (server). With manual
Compose, put them in a `.env` next to your compose files (copy
[.env.example](.env.example)); with `docker run`, pass them as `-e NAME=value`.

| Variable | Default | What it does |
|---|---|---|
| `DEEPSEEK_API_KEY` | — | Your provider key. Optional — you can enter it in the GUI instead. |
| `DEEPSEEK_BASE_URL` | — | Point at a compatible endpoint instead of api.deepseek.com. |
| `DSH_WEB_PORT` | `3080` | The port on **your** machine — it is what the startup banner prints. With Compose it also sets the `-p` mapping. With `docker run` you choose it in `-p <port>:3080`; add `-e DSH_WEB_PORT=<port>` so the banner matches. |
| `DSH_PUBLIC_URL` | — | *(Server mode)* Origin remote clients actually reach (e.g. `http://192.168.1.5:3080` or `https://harness.example`). When set, the printed tokenized "dsh web:" URL uses it instead of `http://localhost:DSH_WEB_PORT`, so the URL is clickable from another machine. |
| `DSH_WEB_AUTH_MODE` | `token` | How the per-run session token is handled. `token` (default) keeps the app's `401`/token dance. `trust-proxy` makes the bundled proxy exchange the token itself — no 401, no token URL, the printed URL is clean. Set it **only** when a real access layer stands in front (TLS+auth edge, VPN, loopback); on a plain `0.0.0.0` publish it opens the GUI to anyone who can reach the port — **LAN access is by definition insecure**. See [Skip the token](#skip-the-session-token-trust-the-layer-in-front). |
| `DSH_BIND_ADDRESS` | `127.0.0.1` local / `0.0.0.0` server | The address the GUI is published on. Local mode default means this machine only; **server mode defaults to `0.0.0.0`** (see [Server mode](#server-mode)). |
| `DSH_HOME_DIR` | volume | *(Local compose only)* Host folder for the harness data, e.g. `~/.dsh` to share with a native install. Server mode always uses the `dsh-server-home` volume. |
| `DSH_WORKSPACE_DIR` | volume | *(Local compose only)* Host folder the agent works in, e.g. `./my-project`. Server mode always uses the `dsh-server-workspaces` volume at `/workspaces`. |
| `DSH_TAG` | `latest` | *(Compose only)* Image version: `latest` or a pinned release like `0.1.2-alpha.2`. |
| `DSH_ALLOW_REMOTE_SETTINGS` | off / `1` server | The GUI's Settings pages (provider config, the `settings.yaml` document) — upstream serves them only to a browser on a loopback page, so a remote browser normally gets *"settings are unavailable in this browser"*. This image patches the client to honor the switch instead: `1` lets a remote browser read/edit Settings, `0` or unset keeps the upstream loopback-only behavior. **Server mode defaults it to `1`** (a server install is reached over a network by definition, and the layer in front of the proxy is the real access gate); set `DSH_ALLOW_REMOTE_SETTINGS=0` to restore upstream behavior. See [Remote browser Settings](#remote-browser-settings). |
| `DSH_TELEMETRY_DISABLED` | — | Any non-empty value opts out of harness telemetry. |
| `DSH_QUIET` | — | Silences the container's startup banner. |

> **`DSH_*` variables are refused from a `.env` file (by design).** Inside the
> container the `dsh` CLI loads an optional `.env` from the workspace layer
> (the invoking directory) and from the harness home. It hard-refuses any
> **bootstrap-only** variable there: every `DSH_*` name, plus a fixed list
> (`DEEPSEEK_BASE_URL`, `HTTP(S)_PROXY`, `PYTHONPATH`, `NODE_OPTIONS`, …), with
> an error like
> `/workspace/.env sets "DSH_BIND_ADDRESS", which only the launching environment may set`.
> Those variables decide *how the process starts or how it reaches the network*,
> so they may only be supplied by the **launching** environment — compose
> `environment:`, `docker run -e`, or an exported shell variable. That is why
> the shipped compose files pass every `DSH_*` setting through the container
> environment rather than a `.env` file. Rule of thumb: an `.env` inside the
> *workspace* folder is for plain user settings (e.g. `DEEPSEEK_API_KEY`); keep
> `DSH_*` and the other listed names out of it. The one-liner is already safe:
> it keeps its settings `.env` in `~/.dsh-container` (never mounted into the
> container) and refuses an install dir that would be the workspace — so only a
> `.env` you keep in the workspace yourself can ever hit this (see
> Troubleshooting). A `.env.example` copied next to your own compose files is
> fine as long as that folder isn't also mounted as the workspace.

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
| install/start Local mode | `curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \| sh -s -- local` (or `docker compose up -d`) |
| install/start Server mode | `curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \| sh -s -- server` (or `docker compose -f docker-compose.server.yml --env-file .env.server up -d`) |
| see what it's doing | `docker logs -f dsh` (local) / `docker logs -f dsh-server` (server) |
| get the access URL (session token) | `docker logs dsh \| grep 'dsh web:'` (local) / `... dsh-server \| grep 'dsh web:'` (server) |
| stop it (keeping data) | `docker stop dsh` / `docker compose down` (local) — server: `docker compose -f docker-compose.server.yml down` |
| start it again | `docker start dsh` / `docker compose up -d` (local) — server: `... -f docker-compose.server.yml up -d` |
| update to the newest image | `curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \| sh -s -- update` (refreshes templates, pulls, restarts whatever is running) |
| get a shell inside | `docker exec -it dsh bash` (local) / `docker exec -it dsh-server bash` (server) |
| install a plugin | `docker exec -it dsh dsh plugin --profile web add <package>` |
| run a one-shot task | `docker exec -it dsh dsh --profile headless "run the tests"` |
| see container usage help | `docker run --rm ghcr.io/andreasseidl/dsh-docker:latest container-help` |
| back up my data | local: `docker run --rm -v dsh-home:/data -v "$PWD":/out alpine tar czf /out/dsh-backup.tgz -C /data .` — server: same with `-v dsh-server-home:/data` and also `-v dsh-server-workspaces:/ws` for the workspace files |
| start completely fresh | `docker compose down -v` (⚠️ deletes settings, history, and workspace) |

---

## Adding executables (no rebuild)

The image ships a lean runtime on a read-only filesystem and bakes in only the
recommended utilities. To make another executable available to the harness and
every agent, drop the file into `~/.dsh/.local/bin` on the `dsh-home` volume —
it's first on `PATH`, so a single static binary becomes a command immediately
(no reload, no rebuild):

```sh
docker cp ./my-tool dsh-server:/home/dsh/.dsh/.local/bin/
docker exec dsh-server chmod +x /home/dsh/.dsh/.local/bin/my-tool
```

Agents install the tooling **they** need into their own workspace — the one
place their sandbox permits writes — and it persists on the workspace volume.

---

## Troubleshooting

**`<path>/.env sets "DSH_…", which only the launching environment may set`.** The
harness refuses bootstrap-only variables — every `DSH_*` name plus a fixed list
(`DEEPSEEK_BASE_URL`, proxies, `PYTHONPATH`, …) — from any `.env` it loads as a
workspace/home config layer; they may only come from the process environment
(`-e`, compose `environment:`, shell export). The installer keeps its `.env` in
`~/.dsh-container` and refuses an install dir equal to the workspace, so this
only happens if you yourself have placed a `.env` containing `DSH_*` inside the
workspace (e.g. copied `.env.example` there). Fix: remove the `DSH_*` lines
from that `.env` (or the file) and pass the settings another way — e.g.
`DSH_WEB_PORT=9000 docker compose up -d` or by editing the compose
`environment:` — then restart.

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

**Local mode: by default nothing on your network can reach the GUI.** The port
is published on `127.0.0.1`, so the kernel only ever accepts connections from
the machine running Docker — a browser anywhere else doesn't get refused, it
doesn't get a connection at all. **Server mode is the opposite by design**: its
compose file publishes on `0.0.0.0` so the GUI is reachable from the network
(see [Server mode](#server-mode) for what to do about that).

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

## SSH (git over SSH)

The container ships a full OpenSSH client and a **persisted** SSH setup, so an
unattended agent can `git clone git@host:user/repo` without a human to type a
password or accept a host key.

- The SSH directory lives on the **`$DSH_HOME` volume** at
  `/home/dsh/.dsh/.ssh` (owned by the `dsh` user) — nothing private sits on the
  image's writable layer, so it survives container recreation.
- On first boot the entrypoint seeds `$DSH_HOME/.ssh/config` (0600) from
  `container/defaults/ssh-config` (idempotent, never overwrites your edits).
  The `dsh` user's own `~/.ssh/config` is baked into the image with a single
  `Include` of it, so it behaves exactly like a normal `~/.ssh/config` — one
  include path, no `/etc/ssh/ssh_config.d/` duplication (the agent runs as the
  `dsh` user, whose user config is what git/ssh read).
- The seeded config sets `StrictHostKeyChecking accept-new` and persists
  `known_hosts` on the volume: first contact with a new host succeeds
  unattended and that host stays trusted across restarts.
- No identity is hard-coded. Drop a key in (`chmod 600`), point an
  `IdentityFile` at it in `.ssh/config`, and cloning works.

**Managing SSH identities from the web** — the image bundles
[`dsh-ssh-manager`](https://github.com/AndreasSeidl/dsh-ssh-manager), which adds
an **SSH** card to **Settings → Plugins → Plugin configuration**. There you
paste a host URL, user and private key, and the plugin writes the per-host
`Host` block, the key (`0600`) and its derived public key under
`$DSH_HOME/.ssh` for you. The plugin itself is **installed in the image**
(baked into the harness's own `node_modules` and resolvable in-box by every
profile, with no pnpm store or network involved); the entrypoint only tells
the volume-backed `web` profile to load it — it seeds a fresh volume's profile
from `container/defaults/web-profile`, or merges `dsh-ssh-manager` into an
existing profile's manifest on its next boot (both Local and Server mode). A
manual `dsh plugin` step is never required:

```sh
docker exec -it dsh dsh plugin --profile web add dsh-ssh-manager   # optional, e.g. other profiles
```

To remove it deliberately, `docker exec -it dsh dsh plugin --profile web remove
dsh-ssh-manager` (which drops the bundle from the profile manifest — the
in-image package itself stays, harmless, just no longer a layer) and delete the
marker `/home/dsh/.dsh/.dsh-container/.ssh-manager-installed` (otherwise the
entrypoint registers it again on the next boot).

**Upgrading dsh-ssh-manager.** Because the plugin is baked into the image, an
upgrade is a new image build, not a per-container pnpm step:

1. Download the new release tarball into
   `container/plugins/dsh-ssh-manager/` (replace the old one — keep exactly one
   `dsh-ssh-manager-*.tgz` there) and rebuild the image (`make build`). The
   build derives the version from the tarball itself, nothing is hand-pinned.
2. Start a container from the new image. Every fresh volume gets the new
   version out of the box; **existing volumes self-upgrade on their next
   boot** — the entrypoint re-aligns the recorded version in
   `$DSH_HOME/profiles/web/package.json` up to the image's version (logged as
   `recording image version … → …`), so the plugin that runs is always the
   image's, and a stray `pnpm install` in the profile can't silently pull an
   older published copy. The managed `$DSH_HOME/.ssh/config.d/*` host
   configuration and keys are version-independent and are kept as-is.

Optionally, without rebuilding, an operator can pull a newer published copy
into the running profile with the documented pnpm path —
`docker exec -it dsh dsh plugin --profile web add dsh-ssh-manager@<version>` —
which then wins over the embedded copy (profile-local nearest-wins); the
embedded version simply remains until the next image build, and the entrypoint
never downgrades a profile that is already ahead.

---

## Reference

<details>
<summary><b>All environment variables</b></summary>

### Web server

| Variable | Default | Maps to | Notes |
|---|---|---|---|
| `DSH_WEB_PORT` | `3080` | banner/display only | The host port you publish the GUI on, used by the startup banner. Inside the container the GUI is always on `3080`. |
| `DSH_PUBLIC_URL` | — | printed ready URL | Origin remote clients actually reach (e.g. `http://192.168.1.5:3080` or `https://harness.example`); the printed "dsh web:" line carries it. |
| `DSH_WEB_AUTH_MODE` | `token` | proxy auth handling | `trust-proxy` makes the bundled proxy exchange the per-run token itself (no 401/token dance). ONLY with a real access layer in front — see [Skip the session token](#skip-the-session-token-trust-the-layer-in-front). |
| `DSH_WEB_NO_OPEN` | `1` | `dsh web --no-open` | Containers have no browser; set `0` to allow the browser-handoff path. |
| `DSH_WEB_ARGS` | — | raw extra args | Must start with `-`; passed through to `dsh web` for exotic flags. |
| `DSH_WORKSPACE` | `/workspace` | process cwd (default workspace) | The in-container path; back it with a volume. |
| `DSH_ALLOW_REMOTE_SETTINGS` | off / `1` server | client Settings gate | `1` lets a remote browser read/edit the Settings pages (upstream serves them only to loopback pages); `0`/unset = upstream behavior. Server mode defaults to `1`; see [Remote browser Settings](#remote-browser-settings). |
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
| `/home/dsh/.dsh` | the harness home (`$DSH_HOME`): **all** persistent harness data | a named volume (`dsh-home` / `dsh-server-home`), a host directory (Local mode, `DSH_HOME_DIR`) |
| `/workspace` | the agent's **workspace** — the directory it reads and edits files in (Local mode) | a named volume (`dsh-workspace`) or a host bind mount of real code |
| `/workspaces` | the **workspace volume root** — every workspace is one subdirectory of it (Server mode) | a named volume (`dsh-server-workspaces`) |

```
/home/dsh/.dsh/
├── profiles/            # per-profile dirs: package.json, cordis.patch.yml (YOUR patch layer, hot-reloaded)
│   ├── node_modules/    # launcher-maintained flat plugin links (re-healed at every boot; dsh-ssh-manager lands here from the image)
│   └── web/             # the volume-backed web profile (dsh-ssh-manager is registered in its manifest)
├── .pnpm-store/         # pnpm content store for `dsh plugin add` (persists installs)
├── .ssh/                # the SSH dir the container's client uses (see "SSH (git over SSH)")
│   ├── config           # seeded once from container/defaults/ssh-config; edit freely
│   └── known_hosts      # host-key trust, persisted
├── .dsh-container/      # container-managed state (plugin provisioning marker)
├── settings.yaml        # seeded on first boot; model selection, UI preferences
├── .credentials.yaml    # provider credentials
├── sessions/            # conversation history
├── storages/            # persisted storage domains
└── .agent-presets/      # agent presets you author
```

On first boot the image seeds an empty `$DSH_HOME` with a scaffold
`settings.yaml` (empty, so stock defaults apply), a persisted SSH setup (see
[SSH (git over SSH)](#ssh-git-over-ssh)), and — in this image — the
volume-backed `web` profile already **names the bundled dsh-ssh-manager**
plugin (which itself lives in the image and resolves in-box; the entrypoint
just seeds/registers the profile so it is loaded), then auto-initializes it.
Existing files are never overwritten. In **server mode** an extra
`cordis.patch.yml` — which pins the web profile to the in-app directory browser
(see [Server mode](#server-mode)) — is seeded as well.

Inside the container the `dsh` user owns `/workspace`, `/home/dsh`, and the
install at `/app`. Everything else is reachable only through volumes you mount,
so the agent can never touch host files outside them. With Compose the root
filesystem is additionally read-only.

</details>

<details>
<summary><b>Picking a tag</b></summary>

- **`:latest`** — the latest *published release*. What you want to try it out.
- **`:<version>`** — a pinned release, e.g. `0.1.2-alpha.2`. Pin this in production.

New upstream releases are picked up automatically: the container repo polls
for upstream `dsh-v*` releases every hour and, when a newer one exists, builds
and publishes both architectures under its version plus `:latest` — no manual
tag push needed. With a pinned `:<version>` you stay on exactly that release
until you choose to bump it. (There is no `:nightly` — only real upstream
releases are ever published.)

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

**Bundled out of the box:** the image ships the **dsh-ssh-manager** plugin (an
SSH identities card in Settings → Plugins, see
[SSH (git over SSH)](#ssh-git-over-ssh)). It is **installed in the image**
itself — baked into the harness's own `node_modules` and resolvable in-box by
every profile, with no pnpm step — and the volume-backed `web` profile is
seeded (fresh volume) or merged (existing deployment) to name it, so it loads
on first boot with no manual step needed. The in-box resolution also means the
plugin keeps working even if `profiles/web/node_modules` is empty or the
volume's pnpm store is unavailable.

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
- **Server mode has no per-workspace hard isolation boundary**. The file
  sandbox (`workspace-write`) confines each session to its own workspace
  directory, but the in-app browser and `workspace.create` accept arbitrary
  paths, and the workspaces *harness home* is on the same machine — this is
  scoping for one server you trust, not a multi-tenant security boundary (same
  trust model as the log token itself). The browse dialog starts at the
  harness home, not the workspace root, so operators may have to navigate to
  `/workspaces`; the seeded `workspaces` symlink in the home directory makes
  that a single click.
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

#!/bin/sh
# Docker entrypoint for the DeepSeek Harness container.
#
# Serves the GUI on port 3080 — the port upstream documents — through the
# bundled reverse proxy, so `docker run -p 3080:3080` and every
# `http://localhost:3080` in the harness's own docs work unchanged.
#
# `dsh web` itself runs behind that proxy on a high loopback-only port
# (127.0.0.1:30800) so it never collides with the dev servers the agent starts
# inside the container. Both ports are fixed internals; nothing to configure.
#
# Everything a deployment needs to configure is an environment variable; no
# image internals have to be edited.
#
# Env vars consumed here (beyond the ones the harness itself reads straight
# from the process environment, which all pass through untouched):
#   DSH_SERVER_MODE      Any non-0 value switches this container to SERVER
#                        mode: the default workspace root becomes /workspaces
#                        (backed by the dsh-workspaces volume), the web
#                        profile pins the in-app directory browser (so remote
#                        operators pick/create workspaces without any host
#                        display), a `workspaces` symlink appears in the
#                        harness home so the browser starts at the workspace
#                        root. See docker-compose.server.yml.
#   DSH_WORKSPACE        Working directory the harness uses as its default
#                        workspace root (its process.cwd). Defaults to
#                        /workspace — the volume-backed agent workspace
#                        (/workspaces in server mode).
#   DSH_WEB_PORT         The port on YOUR machine the GUI is published on
#                        (default 3080). The startup banner prints it, and the
#                        proxy uses it to rewrite the app's tokenized ready-URL
#                        line to the public origin. With `docker compose` this
#                        is passed through automatically; with `docker run` set
#                        it to match your `-p <port>:3080`. The GUI port
#                        INSIDE the container is always 3080.
#   DSH_PUBLIC_URL       The origin (scheme://host[:port], no path) remote
#                        clients actually reach this GUI at. When set, the
#                        proxy prints the tokenized "dsh web:" URL with that
#                        origin instead of http://localhost:DSH_WEB_PORT — the
#                        fix for LAN/server use, where the token URL must be
#                        clickable from another machine (e.g.
#                        http://192.168.1.5:3080 or, behind a TLS proxy,
#                        https://harness.example).
#   DSH_WEB_AUTH_MODE    How the per-run session token is handled:
#                          token       (default) the app gates every request;
#                                      clients open the printed ?token= URL once.
#                          trust-proxy the bundled proxy exchanges the token
#                                      itself and replays the cookie, so there
#                                      is no 401/token dance — the printed URL
#                                      is plain. Use ONLY when a real access
#                                      layer stands in front (Tailscale ACL,
#                                      TLS + auth edge, VPN, loopback); on
#                                      a plain 0.0.0.0 publish it opens the GUI.
#
# NOTE: who may reach the GUI is NOT decided in here. The proxy binds every
# interface in the container's network namespace, because a published port has
# nothing to connect to otherwise. The access boundary is the port mapping you
# choose on the host: `-p 127.0.0.1:3080:3080` serves this machine only (the
# kernel refuses everything else), `-p 3080:3080` opens it to your network.
# With compose that is the DSH_BIND_ADDRESS variable. There is no authentication.
#   DSH_WEB_ARGS         Extra raw arguments appended after the mapped flags
#                        (must start with "-"; useful for exotic knobs).
#   DSH_QUIET            Non-empty silences the container's startup banner
#                        (the URL / volume / credentials summary printed
#                        before the harness itself starts).
#
# Two convenience modes are handled by the container rather than the CLI:
#   `shell`          -> an interactive bash shell with the same user and mounts
#   `container-help` -> a short usage summary for this image
#
# On the FIRST boot of an empty $DSH_HOME volume the entrypoint seeds a default
# settings.yaml from the image-provided copy under /opt/dsh/defaults. Existing
# files are never touched.
#
# Every other variable (DSH_HOME, DSH_TELEMETRY_DISABLED,
# DEEPSEEK_API_KEY, DEEPSEEK_BASE_URL, provider keys, HTTP(S)_PROXY, TZ, ...)
# is inherited straight into the process and the harness's layered environment.
set -eu

DSH_BIN=/usr/local/bin/dsh
DSH_HOME="${DSH_HOME:-/home/dsh/.dsh}"

# ── Friendly startup output ───────────────────────────────────────────────
# A container hides everything a local install would show you: whether your
# data is actually on a volume, where the GUI is, whether a key is configured.
# The banner answers those three questions on every boot, and only nags when
# something is actually wrong. Set DSH_QUIET=1 to silence it.

# True when $1 is a mount point (i.e. backed by a volume or bind mount) rather
# than a directory living inside the container's own writable layer.
is_mounted() {
  awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
}

# True when the harness has some way to reach a model: an API key in the
# environment, a credentials file, or an apiKey in settings.yaml.
has_credentials() {
  for v in "${DEEPSEEK_API_KEY:-}" "${DSH_API_KEY:-}"; do
    [ -n "$v" ] && return 0
  done
  [ -s "$DSH_HOME/.credentials.yaml" ] && return 0
  grep -qE '^[[:space:]]*apiKey:[[:space:]]*[^[:space:]#]' "$DSH_HOME/settings.yaml" 2>/dev/null && return 0
  return 1
}

print_boot_banner() {
  [ -n "${DSH_QUIET:-}" ] && return 0
  workspace="${DSH_WORKSPACE:-/workspace}"
  web_port="${DSH_WEB_PORT:-3080}"

  echo "" >&2
  echo "  DeepSeek Harness — starting the web GUI" >&2
  echo "  ───────────────────────────────────────────────────────────────" >&2
  echo "  Open        http://localhost:${web_port}" >&2
  if [ "${DSH_WEB_AUTH_MODE:-token}" = "trust-proxy" ]; then
    echo "  Access      delegated: the bundled proxy exchanges the session token" >&2
    echo "              itself — open the \"dsh web:\" URL (no token needed). The" >&2
    echo "              real gate is the layer in front (Tailscale ACL, TLS" >&2
    echo "              + auth, VPN). Do NOT trust this on a plain 0.0.0.0 publish." >&2
  else
    echo "  Access      session-locked: open the \"dsh web:\" URL printed in the" >&2
    echo "              logs (it carries the one-time session token)" >&2
  fi
  echo "  Data        ${DSH_HOME}" >&2
  echo "  Workspace   ${workspace}" >&2
  if [ "${DSH_SERVER_MODE:-0}" != "0" ]; then
    echo "  Mode        server (remote-safe): workspaces are created under" >&2
    echo "              ${workspace} in the web GUI's in-app directory browser" >&2
  fi
  echo "  Shell in    docker exec -it $(hostname) bash" >&2
  echo "" >&2

  if ! is_mounted "$DSH_HOME"; then
    echo "  ! ${DSH_HOME} is NOT on a volume — your settings, credentials and" >&2
    echo "    chat history are deleted when this container is removed." >&2
    echo "    Fix:  -v dsh-home:${DSH_HOME}" >&2
    echo "" >&2
  fi
  if ! is_mounted "$workspace"; then
    echo "  ! ${workspace} is NOT on a volume — files the agent writes are" >&2
    echo "    deleted when this container is removed." >&2
    echo "    Fix:  -v dsh-workspace:${workspace}   (or a host directory:" >&2
    echo "          -v \"\$PWD\":${workspace} to work on your own code)" >&2
    echo "" >&2
  fi
  # A host directory mounted at /workspace keeps its HOST ownership, which is
  # usually a different uid than the container's unprivileged user — the agent
  # then reads the code fine but cannot save a single edit. Say so up front
  # rather than letting it surface as an EACCES mid-session.
  if [ -d "$workspace" ] && [ ! -w "$workspace" ]; then
    echo "  ! ${workspace} is read-only for the container user (uid $(id -u))." >&2
    echo "    The agent can read your files but cannot save changes." >&2
    echo "    Fix on the host:  sudo chown -R $(id -u):$(id -g) <that folder>" >&2
    echo "    (or chmod -R a+rwX it, if you would rather not change owners)" >&2
    echo "" >&2
  fi
  if [ -d "$DSH_HOME" ] && [ ! -w "$DSH_HOME" ]; then
    echo "  ! ${DSH_HOME} is read-only for the container user (uid $(id -u))." >&2
    echo "    Settings and chat history cannot be saved. If you mounted a host" >&2
    echo "    folder here, run:  sudo chown -R $(id -u):$(id -g) <that folder>" >&2
    echo "" >&2
  fi
  if ! has_credentials; then
    echo "  i No model credentials found yet. Either set one at start:" >&2
    echo "      -e DEEPSEEK_API_KEY=sk-..." >&2
    echo "    or add your provider key in the GUI's Settings page — it is" >&2
    echo "    saved to ${DSH_HOME} and reused on every restart." >&2
    echo "" >&2
  fi
}

print_container_help() {
  cat >&2 <<'HELP'
DeepSeek Harness container — usage

  Run the web GUI (the default):
    docker run -d --name dsh -p 127.0.0.1:3080:3080 \
      -v dsh-home:/home/dsh/.dsh -v dsh-workspace:/workspace \
      -e DEEPSEEK_API_KEY=sk-... \
      IMAGE
    then open http://localhost:3080

  Ports: the GUI is served on 3080, the port upstream documents. The address
  you publish it on IS the access control -- `-p 127.0.0.1:3080:3080` serves
  this machine only, `-p 3080:3080` opens it to your whole network, and there
  is no login screen. (`dsh web` itself runs behind the bundled proxy on
  127.0.0.1:30800, internal to the container.)

  Work on your own code -- bind your project as the workspace:
      -v "$PWD":/workspace

  Server mode -- separate volumes for harness data and workspaces, on the
  network by default (publish 0.0.0.0; there is no login, only the log token):
    docker run -d --name dsh-server -p 0.0.0.0:3080:3080 \
      -v dsh-home:/home/dsh/.dsh -v dsh-workspaces:/workspaces \
      -e DSH_SERVER_MODE=1 -e DSH_WORKSPACE=/workspaces \
      -e DEEPSEEK_API_KEY=sk-... \
      IMAGE
    then open the "dsh web:" URL from `docker logs dsh-server` (replace
    localhost with this server's address). Workspaces are created per
    subdirectory of /workspaces in the web GUI's in-app directory browser.

Modes (first argument):
  web                  the web GUI (default)
  shell                an interactive bash shell with the same mounts
  plugin ... add PKG   install a harness plugin into a profile
  container-help       this message
  anything else        passed straight through to the `dsh` CLI,
                       e.g. `--profile headless "run the tests"`

Common environment variables:
  DEEPSEEK_API_KEY     provider key (or configure it in the GUI Settings page)
  DSH_WEB_PORT         host port the GUI is published on (banner only; default
                       3080 — set it to match your `-p <port>:3080`)
  DSH_QUIET=1          silence this container's startup banner

Volumes (mount both, or your work is lost on `docker rm`):
  /home/dsh/.dsh       settings, credentials, chat history, plugins
  /workspace           the directory the agent reads and writes files in

Full documentation: https://github.com/AndreasSeidl/dsh-docker
HELP
}

# ── First-boot volume initialization ──────────────────────────────────────
# Idempotent: seeds scaffold files into an empty $DSH_HOME, never overwrites.
mkdir -p "$DSH_HOME" 2>/dev/null || true

# ── Server mode (DSH_SERVER_MODE != 0) ────────────────────────────────────
# Layout: the harness home stays on the dedicated dsh-home volume, and a
# second volume mounts at /workspaces. Operators create one workspace per
# subdirectory of /workspaces from the web GUI (each session then runs with
# that subdirectory as its cwd, and the file sandbox confines its writes
# there). Work done before the generic first-boot seeding below:
#   * default the workspace root to /workspaces,
#   * seed a cordis.patch.yml that pins the in-app directory browser (the
#     remote-safe picker) — never a native OS dialog on an unattended server,
#   * symlink the workspace root into the harness home so the browser's
#     home-anchored listing starts at /workspaces.
if [ "${DSH_SERVER_MODE:-0}" != "0" ]; then
  if [ -z "${DSH_WORKSPACE:-}" ]; then
    DSH_WORKSPACE="/workspaces"
    export DSH_WORKSPACE
  fi
  # A server install is reached over a network by definition, so the GUI's
  # page hostname is never loopback and upstream deliberately disables the
  # Settings pages ("settings are unavailable in this browser"). The container
  # patches the client to honor DSH_ALLOW_REMOTE_SETTINGS instead, and server
  # mode makes remote Settings available BY DEFAULT: the access gate is the
  # layer in front of the proxy (Tailscale/TLS/VPN/loopback publish), and the
  # operator who already reached that gate should be able to edit provider
  # keys. Set DSH_ALLOW_REMOTE_SETTINGS=0 to restore the upstream
  # loopback-only behavior.
  if [ -z "${DSH_ALLOW_REMOTE_SETTINGS:-}" ]; then
    DSH_ALLOW_REMOTE_SETTINGS=1
    export DSH_ALLOW_REMOTE_SETTINGS
  fi
  if [ -d "$DSH_HOME" ] && [ -w "$DSH_HOME" ]; then
    if [ ! -e "$DSH_HOME/cordis.patch.yml" ] && [ -f "/opt/dsh/defaults/cordis.patch.yml" ]; then
      cp "/opt/dsh/defaults/cordis.patch.yml" "$DSH_HOME/cordis.patch.yml" 2>/dev/null || true
      [ -f "$DSH_HOME/cordis.patch.yml" ] && echo "dsh: seeded server-mode cordis.patch.yml into $DSH_HOME (pins the in-app directory browser)" >&2
    fi
    # The in-app browser lists the home directory first; a `workspaces` entry
    # there takes the operator straight to the workspace root.
    if [ -d "$DSH_WORKSPACE" ] && [ ! -e "/home/dsh/workspaces" ]; then
      ln -s "$DSH_WORKSPACE" "/home/dsh/workspaces" 2>/dev/null || true
    fi
  fi
fi

if [ -d "$DSH_HOME" ] && [ -w "$DSH_HOME" ]; then
  for f in settings.yaml; do
    if [ ! -e "$DSH_HOME/$f" ] && [ -f "/opt/dsh/defaults/$f" ]; then
      cp "/opt/dsh/defaults/$f" "$DSH_HOME/$f"
      echo "dsh: seeded default $f into $DSH_HOME" >&2
    fi
  done
  # pnpm's content-addressed store lives on the volume so plugin installs stay
  # fast and persistent; make sure it exists and is writable.
  mkdir -p "$DSH_HOME/.pnpm-store"
  # SSH credentials persist on the SAME volume as everything else the harness
  # owns. The system /etc/ssh/ssh_config.d/99-dsh-container.conf includes the
  # user config here, so this seeds (idempotent — never touches what is
  # already there):
  #   * .ssh/       0700 — the client's IdentityFile/known_hosts point here,
  #                        so keys dropped in this directory persist;
  #   * .ssh/config 0600 — the actual ssh_config, seeded once from the baked
  #                        default (/opt/dsh/defaults/ssh-config). Edit it
  #                        freely: per-host blocks, key paths, ports, proxy….
  # Drop an unencrypted deploy key (e.g. id_ed25519, chmod 600) into
  # "$DSH_HOME/.ssh/" and `git clone git@github.com:...` works from the agent.
  mkdir -p "$DSH_HOME/.ssh"
  chmod 700 "$DSH_HOME/.ssh"
  if [ ! -e "$DSH_HOME/.ssh/config" ] && [ -f "/opt/dsh/defaults/ssh-config" ]; then
    cp "/opt/dsh/defaults/ssh-config" "$DSH_HOME/.ssh/config"
    chmod 600 "$DSH_HOME/.ssh/config"
    echo "dsh: seeded default ssh config ($DSH_HOME/.ssh/config) — edit it or drop SSH keys into $DSH_HOME/.ssh/" >&2
  fi
fi

# ── Operator-extensible executables ─────────────────────────────────────────
# The image ships a deliberately lean runtime on a read-only filesystem, so
# there is no "edit the image to add a tool" workflow: everything extra lives
# on the PERSISTED home volume, no rebuild needed. The whole mechanism:
#   * "$DSH_HOME/.local/bin" is FIRST on PATH — the operator drops any single
#     static executable there (docker cp, or a bind mount of the volume) and
#     it becomes a command for the harness and every process the agent spawns.
#   * Agents install the tooling THEY need into their own workspace — the one
#     place their sandbox permits writes — and it persists on the workspace
#     volume.
# Nothing else is baked in.
if [ -d "$DSH_HOME" ] && [ -w "$DSH_HOME" ]; then
  mkdir -p "$DSH_HOME/.local/bin" 2>/dev/null || true
fi
case ":$PATH:" in
  *":$DSH_HOME/.local/bin:"*) ;;
  *) export PATH="$DSH_HOME/.local/bin:$PATH" ;;
esac

# The invoking directory is the harness's default workspace root (the same
# rule as `pnpm dsh web`). In the container that is the workspace the user
# backs with a volume; relocate it with DSH_WORKSPACE.
workspace="${DSH_WORKSPACE:-/workspace}"
if [ ! -d "$workspace" ]; then
  echo "dsh: the workspace directory '$workspace' does not exist inside the container." >&2
  echo "dsh: mount one, e.g.  -v dsh-workspace:/workspace  (or a host dir:" >&2
  echo "dsh:   -v \"\$PWD\":/workspace ), or point DSH_WORKSPACE at an existing path." >&2
  exit 1
fi
cd "$workspace" || exit 1

# First positional selects the dsh mode. `web` (the default) gets the env
# mapping; anything else passes straight through — note we do NOT shift, every
# original argument has to reach the CLI (`dsh --version`, `dsh
# --profile headless "run"`, `dsh plugin ...`, `dsh --profile web
# --dump-default-config`).
mode="${1:-web}"

# Convenience modes handled by the container itself (everything else is a real
# `dsh` invocation and passes through untouched).
case "$mode" in
  shell|bash|sh)
    # `docker run ... <image> shell` -> an interactive shell in the workspace,
    # with the same user, mounts and PATH the harness runs under. Saves the
    # `--entrypoint` dance. Any further arguments go to bash, so
    # `... shell -c 'dsh --version'` works too.
    shift
    exec /bin/bash "$@"
    ;;
  container-help|--container-help)
    print_container_help
    exit 0
    ;;
esac

if [ "$mode" != "web" ]; then
  exec "$DSH_BIN" "$@"
fi
if [ "$#" -gt 0 ]; then shift; fi

print_boot_banner

# --no-open for containers (no default browser). Opt out with DSH_WEB_NO_OPEN=0.
no_open_args=""
if [ "${DSH_WEB_NO_OPEN:-1}" != "0" ]; then
  no_open_args="--no-open"
fi

# The web stack is always the same shape: the bundled reverse proxy on 3080
# with `dsh web` behind it on 127.0.0.1:30800. The proxy rewrites Host/Origin
# to loopback as it forwards, so the harness's /api trust fence and the
# browser's same-origin rules both hold with no config, and WebSocket upgrades
# are transported the same way. Publish 3080: `docker run -p 3080:3080`.
#
# Newer harness profiles lock the GUI behind a per-run ?token= session: they
# 401 until the browser exchanges the printed token for a cookie (303 +
# Set-Cookie, authority-bound to the loopback origin the proxy presents). The
# proxy forwards that dance untouched and rewrites the app's ready-URL line to
# the public origin (using DSH_WEB_PORT), so the user opens the log's
# "dsh web:" URL and the GUI just works.
#
# shellcheck disable=SC2086  # deliberate word-splitting of mapped flags
exec /usr/local/bin/node /usr/local/lib/dsh-container/reverse-proxy.mjs \
  $no_open_args \
  ${DSH_WEB_ARGS:-} \
  "$@"

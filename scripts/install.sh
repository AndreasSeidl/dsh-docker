#!/bin/sh
#
# dsh-container installer — DeepSeek Harness GUI in Docker.
#
# Two ways to run it:
#
#   1) One line, from anywhere. Fetches the compose files into
#      $HOME/.dsh-container (override with DSH_CONTAINER_DIR) and runs there:
#
#        curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \
#          | sh -s -- local
#        curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \
#          | sh -s -- server
#
#   2) From a checkout of this repository (uses the files right here):
#
#        bash scripts/install.sh local
#        bash scripts/install.sh server
#
#   LOCAL MODE   harness data + workspace are host directories and the GUI is
#                served on this machine only (127.0.0.1). Defaults: harness
#                data in ~/.dsh, the agent works in the directory you run this
#                from. Override with DSH_HOME_DIR / DSH_WORKSPACE_DIR.
#
#   SERVER MODE  harness data AND workspaces live on named volumes, the GUI is
#                published on all interfaces (0.0.0.0) by default, and
#                workspaces are subdirectories of /workspaces created from the
#                web GUI. There is no login — keep the log-printed session token
#                private, and put TLS / a reverse-proxy auth layer in front
#                beyond a trusted LAN (or DSH_WEB_AUTH_MODE=trust-proxy when
#                that layer is a real gate, e.g. tsdproxy/Tailscale).
#
# Other commands: status | update [local|server] | uninstall [--purge] [..] | help
#
set -eu

fail() { printf 'install: %s\n' "$*" >&2; exit 1; }
info() { printf 'install: %s\n' "$*"; }
warn() { printf 'install: %s\n' "$*" >&2; }

# ── Where are the project files? ───────────────────────────────────────────
# Three cases: the script was invoked from inside a checkout (found through $0
# or the current directory), or it was piped in with `curl | sh` and the files
# must be fetched into a dedicated app dir.
is_checkout() { [ -f "$1/docker-compose.yml" ] && [ -f "$1/docker-compose.server.yml" ] && [ -f "$1/.env.server.example" ]; }

SCRIPT_DIR=""
case "$0" in
  */*) SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR="" ;;
esac

if [ -n "$SCRIPT_DIR" ] && is_checkout "$SCRIPT_DIR"; then
  APP_DIR="$SCRIPT_DIR"                       # .../scripts/install.sh -> checkout
  SELF_INSTALL=0
elif [ -n "$SCRIPT_DIR" ] && is_checkout "$(dirname "$SCRIPT_DIR")"; then
  APP_DIR="$(dirname "$SCRIPT_DIR")"          # scripts/<name> in a checkout
  SELF_INSTALL=0
elif is_checkout "$(pwd)"; then
  APP_DIR="$(pwd)"                            # files are right here
  SELF_INSTALL=0
else
  APP_DIR="${DSH_CONTAINER_DIR:-$HOME/.dsh-container}"
  SELF_INSTALL=1
fi

# The directory the user actually ran the installer from — the LOCAL mode
# workspace default (for the one-liner that is where they piped it; for a
# checkout usually the repo root).
INVOKE_DIR="$(pwd)"

if [ "$SELF_INSTALL" -eq 1 ]; then
  command -v curl >/dev/null 2>&1 \
    || fail "the one-line installer needs curl — install curl, or clone the repo and run scripts/install.sh"
  BASE_URL="${DSH_CONTAINER_BASE_URL:-https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main}"
  mkdir -p "$APP_DIR" || fail "cannot create $APP_DIR"
  # Strict https for the official URL; a custom mirror/fork may be plain http.
  if [ "$BASE_URL" = "https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main" ]; then
    CURL_SECURITY='--proto =https --tlsv1.2'
  else
    CURL_SECURITY=''
  fi
  for f in docker-compose.yml docker-compose.server.yml .env.server.example; do
    info "fetching $f -> $APP_DIR"
    curl -fsSL $CURL_SECURITY --retry 2 "$BASE_URL/$f" -o "$APP_DIR/$f" \
      || fail "could not fetch $f from $BASE_URL (offline? wrong branch?)"
  done
  info "project files are in $APP_DIR (point later runs there with DSH_CONTAINER_DIR=$APP_DIR)"
fi

cd "$APP_DIR" || fail "cannot change into $APP_DIR"

# Compose invocations: a checkout runs exactly as `docker compose …` in the repo
# root; a self-installed copy pins the project name so volumes/networks keep the
# same well-known `dsh-container_*` names no matter where the files live.
docker_compose() {
  if [ "$SELF_INSTALL" -eq 1 ]; then
    docker compose --project-name dsh-container "$@"
  else
    docker compose "$@"
  fi
}

require_compose() {
  docker info >/dev/null 2>&1 \
    || fail "can't talk to the Docker daemon — is Docker installed and running?"
  docker compose version >/dev/null 2>&1 \
    || fail "docker compose (v2 plugin) not found — install Docker with the compose plugin."
}

# The per-boot access URL the GUI prints (it carries the one-time session
# token). $1 = container name.
access_url() {
  c="$1"
  url="$(docker logs "$c" 2>/dev/null | grep -o 'dsh web: http://[^ ]*' | tail -n 1 || true)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url"
  else
    printf 'docker logs %s | grep "dsh web:"\n' "$c"
  fi
}

# Compose args for SERVER mode. `--env-file` is only passed when the file
# exists (status/update/uninstall must not fail on a fresh checkout).
server_args() {
  printf '%s' "-f docker-compose.server.yml"
  [ -f .env.server ] && printf ' %s' "--env-file .env.server"
}

# ── local mode ────────────────────────────────────────────────────────────
cmd_local() {
  require_compose

  if [ ! -f .env ]; then
    info "writing .env (local mode: this machine only by default)"
    {
      printf '# dsh-container — LOCAL MODE settings (written by scripts/install.sh)\n'
      printf '# The GUI stays on this machine (127.0.0.1) unless you change DSH_BIND_ADDRESS.\n\n'
      printf 'DEEPSEEK_API_KEY=%s\n' "${DEEPSEEK_API_KEY:-}"
      [ -n "${DEEPSEEK_BASE_URL:-}" ] && printf 'DEEPSEEK_BASE_URL=%s\n' "$DEEPSEEK_BASE_URL"
      printf 'DSH_WEB_PORT=%s\n' "${DSH_WEB_PORT:-3080}"
      printf 'DSH_BIND_ADDRESS=%s\n' "${DSH_BIND_ADDRESS:-127.0.0.1}"
      printf 'DSH_HOME_DIR=%s\n' "${DSH_HOME_DIR:-$HOME/.dsh}"
      printf 'DSH_WORKSPACE_DIR=%s\n' "${DSH_WORKSPACE_DIR:-$INVOKE_DIR}"
      [ -n "${DSH_TAG:-}" ] && printf 'DSH_TAG=%s\n' "$DSH_TAG"
      [ -n "${DSH_IMAGE:-}" ] && printf 'DSH_IMAGE=%s\n' "$DSH_IMAGE"
      [ -n "${DSH_WEB_AUTH_MODE:-}" ] && printf 'DSH_WEB_AUTH_MODE=%s\n' "$DSH_WEB_AUTH_MODE"
    } > .env
  else
    info ".env already exists — leaving it alone (edit it, or rm it to regenerate)"
  fi

  info "starting Local mode (docker compose up -d)"
  docker_compose up -d

  port="$(grep '^DSH_WEB_PORT=' .env | head -n 1 | cut -d= -f2 || true)"
  [ -n "$port" ] || port=3080
  echo ""
  echo "  DeepSeek Harness — LOCAL MODE"
  echo "  This machine only: http://localhost:${port}"
  echo ""
  echo "  Open the session-locked URL from the log (carries the one-time token):"
  echo "    docker logs dsh | grep 'dsh web:'"
  echo ""
  echo "  Harness data:   $(grep '^DSH_HOME_DIR=' .env | cut -d= -f2-)"
  echo "  Workspace:      $(grep '^DSH_WORKSPACE_DIR=' .env | cut -d= -f2-)"
}

# ── server mode ───────────────────────────────────────────────────────────
cmd_server() {
  require_compose

  if [ ! -f .env.server ]; then
    if [ -f .env.server.example ]; then
      cp .env.server.example .env.server
      info "wrote .env.server from .env.server.example — edit it (e.g. add your API key) and re-run"
      info "  (or:  sed -i 's/^DEEPSEEK_API_KEY=.*/DEEPSEEK_API_KEY=sk-.../' .env.server)"
    else
      : > .env.server
    fi
  else
    info ".env.server already exists — leaving it alone (edit it, or rm it to regenerate)"
  fi

  info "starting Server mode (docker compose -f docker-compose.server.yml up -d)"
  docker_compose $(server_args) up -d

  echo ""
  echo "  DeepSeek Harness — SERVER MODE (LAN/internet access by default)"
  echo "  Open the session-locked URL from the log and replace 'localhost' with"
  echo "  this server's address:"
  echo "    docker compose -f docker-compose.server.yml logs dsh-server | grep 'dsh web:'"
  echo ""
  echo "  Workspaces: create one per project in the web GUI's directory browser"
  echo "              (each is a subdirectory of /workspaces on the volume)."
  echo "  NO LOGIN:   the log token is the only gate — treat it like a password,"
  echo "              and put TLS / a reverse-proxy auth layer in front beyond a"
  echo "              trusted LAN."
}

# ── status / update / uninstall ───────────────────────────────────────────
cmd_status() {
  require_compose
  echo "== running stacks =="
  docker_compose ps 2>/dev/null || true
  docker_compose $(server_args) ps 2>/dev/null || true
  echo ""
  if docker inspect dsh >/dev/null 2>&1; then
    echo "LOCAL mode is up: $(access_url dsh)  (open on this machine)"
  fi
  if docker inspect dsh-server >/dev/null 2>&1; then
    echo "SERVER mode is up: $(access_url dsh-server)  (replace localhost with the server address)"
  fi
  if [ ! -e .env ] && [ ! -e .env.server ]; then
    echo "nothing installed yet — try:  sh scripts/install.sh local | server"
  fi
}

cmd_update() {
  require_compose
  which="${1:-auto}"
  [ "$#" -gt 0 ] && shift
  case "$which" in
    local) docker_compose pull && docker_compose up -d ;;
    server) docker_compose $(server_args) pull && docker_compose $(server_args) up -d ;;
    auto)
      if docker inspect dsh-server >/dev/null 2>&1; then cmd_update server
      elif docker inspect dsh >/dev/null 2>&1; then cmd_update local
      else fail "no stack is running — pass local or server explicitly"; fi ;;
    *) fail "update takes local, server or auto (got: $which)" ;;
  esac
  if [ "$SELF_INSTALL" -eq 1 ]; then
    warn "the compose templates were not re-fetched — run the one-liner again (or git pull) for new versions of those"
  fi
}

cmd_uninstall() {
  require_compose
  purge=0
  which=""
  for a in "$@"; do
    case "$a" in
      --purge) purge=1 ;;
      local|server|auto) which="$a" ;;
      *) fail "uninstall takes [--purge] [local|server|auto] (got: $a)" ;;
    esac
  done
  [ -n "$which" ] || which="auto"

  flags=""
  [ "$purge" -eq 1 ] && flags="-v"
  case "$which" in
    local) docker_compose down $flags ;;
    server) docker_compose $(server_args) down $flags ;;
    auto)
      docker_compose down $flags >/dev/null 2>&1 || true
      docker_compose $(server_args) down $flags >/dev/null 2>&1 || true
      if [ "$purge" -eq 1 ]; then
        echo "install: torn down AND deleted volumes"
      else
        echo "install: torn down (data kept)"
      fi ;;
  esac
  [ "$purge" -eq 1 ] && warn "volumes removed — settings, history, workspaces are gone"
}

cmd_help() {
  cat <<'HELP'
dsh-container installer — DeepSeek Harness GUI in Docker

USAGE:
  ./scripts/install.sh <command>          # from a checkout of the repo
  curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh | sh -s -- <command>
                                          # one line, from anywhere

COMMANDS:
  local              LOCAL MODE — host dirs for harness data + workspace,
                     GUI on this machine only (127.0.0.1).
  server             SERVER MODE — persistent volumes for harness data +
                     workspaces, LAN/internet access by default (0.0.0.0).
  status             which stack is running and how to reach it.
  update [mode]      pull the newest image and restart (mode: local|server|auto).
  uninstall [--purge] [mode]   stop; data kept unless --purge (deletes volumes).
  help               this message.

LOCAL DEFAULTS (override via env or edit .env afterwards):
  DSH_HOME_DIR=~/.dsh        harness data (settings, credentials, history)
  DSH_WORKSPACE_DIR=$PWD     the folder the agent works in
  DSH_BIND_ADDRESS=127.0.0.1 this machine only
  DSH_WEB_PORT=3080

SERVER DEFAULTS (override via env or edit .env.server afterwards):
  DSH_BIND_ADDRESS=0.0.0.0   published on every interface — remote access
  DSH_WEB_PORT=3080
  Volumes: dsh-server-home (/home/dsh/.dsh), dsh-server-workspaces (/workspaces)

ONE-LINE (piped) INSTALLS:
  DSH_CONTAINER_DIR=~/.dsh-container   where the compose files are fetched
  DSH_CONTAINER_BASE_URL=...           mirror/fork base URL for the files

ACCESS CONTROL:
  The harness uses the port upstream documents (3080) inside the container; the
  GUI is session-locked — each boot prints a tokenized "dsh web:" URL in the log
  and requests without it get a 401. There is no login screen.
  DSH_WEB_AUTH_MODE=trust-proxy makes the bundled proxy exchange that token
  itself (no 401/token dance) — set it ONLY when a real access layer stands in
  front (tsdproxy/Tailscale, TLS + auth, VPN). On a plain 0.0.0.0 publish leave
  it at the default "token".
HELP
}

# Bare `curl ... | sh` (no subcommand) installs LOCAL mode — the same default
# as the manual docker compose Quick start below. Use `sh -s -- server` for a
# server, and `sh -s -- help` for everything this can do.
case "${1:-local}" in
  local) shift || true; cmd_local ;;
  server) shift || true; cmd_server ;;
  status) shift || true; cmd_status ;;
  update) shift || true; cmd_update "$@" ;;
  uninstall) shift || true; cmd_uninstall "$@" ;;
  help|-h|--help) shift || true; cmd_help ;;
  *) fail "unknown command '$1' — try: ./scripts/install.sh help" ;;
esac

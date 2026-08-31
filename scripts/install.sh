#!/bin/sh
#
# dsh-container installer — DeepSeek Harness GUI in Docker.
#
# ONE mode: the installer always downloads the project files (the two compose
# templates + the .env.server example) into $DSH_CONTAINER_DIR (default
# ~/.dsh-container) and runs the stack from there. It never reads deploy files
# from the current directory — that directory stays yours (it is the LOCAL
# mode workspace by default), and the installer refuses a configuration in
# which the install dir would BE the workspace.
#
# Why: the harness, inside the container, reads a `.env` from the mounted
# workspace and refuses any DSH_* variable in it (only the launching
# environment may set those). Keeping the project files + settings `.env` OUT
# of the workspace makes that collision impossible by construction.
#
# The one complexity this removes: before v1 the script had a "checkout mode"
# that reused compose files found in the current directory (e.g. a clone of
# this repo). That directory was also the default LOCAL workspace, so the
# installer-written `.env` (full of DSH_*) landed INSIDE the workspace and the
# container refused to boot. Checkout mode is gone: run the one-liner, or to
# control the deployment yourself use docker compose / docker run directly
# (see the README Quick start + Server mode sections).
#
#   curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \
#     | sh -s -- local
#   curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh \
#     | sh -s -- server
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

# ── Where do the project files live? ───────────────────────────────────────
# Always $DSH_CONTAINER_DIR (default ~/.dsh-container); the installer is
# single-mode and downloads the templates there. $INVOKE_DIR is where the
# user actually ran the installer from — the LOCAL mode workspace default.
APP_DIR="$(CDPATH= cd -- "${DSH_CONTAINER_DIR:-$HOME/.dsh-container}" 2>/dev/null && pwd || printf '%s\n' "${DSH_CONTAINER_DIR:-$HOME/.dsh-container}")"
INVOKE_DIR="$(pwd)"
norm_dir() { CDPATH= cd -- "$1" 2>/dev/null && pwd || printf '%s\n' "$1"; }

# Guard: the install dir must never BE the workspace. The harness reads the
# settings `.env` from the workspace root and refuses bootstrap-only (DSH_*)
# names in it — if the install dir ever equaled the workspace, the container
# would refuse to start. The default workspace is the directory you ran this
# from; cmd_local below re-checks any explicit DSH_WORKSPACE_DIR.
[ "$APP_DIR" != "$INVOKE_DIR" ] || fail \
  "DSH_CONTAINER_DIR ($APP_DIR) is the same as the directory you are running in — the project files/settings must live OUTSIDE the workspace, or the container will refuse to start. Run from a different directory or set DSH_CONTAINER_DIR."

fetch_files() {
  command -v curl >/dev/null 2>&1 \
    || fail "the installer needs curl — install curl, or deploy manually with docker compose"
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
  info "project files are in $APP_DIR (override with DSH_CONTAINER_DIR=$APP_DIR)"
}

fetch_files

cd "$APP_DIR" || fail "cannot change into $APP_DIR"
APP_DIR="$(pwd)"   # normalized

# Compose invocations. The project name is pinned so the well-known
# `dsh-container_*` volume/network names stay stable no matter where the files
# live (they are always in DSH_CONTAINER_DIR, but never assume that).
docker_compose() {
  docker compose --project-name dsh-container "$@"
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
# exists (status/update/uninstall must not fail on a fresh install dir).
server_args() {
  printf '%s' "-f docker-compose.server.yml"
  [ -f .env.server ] && printf ' %s' "--env-file .env.server"
}

# ── local mode ────────────────────────────────────────────────────────────
cmd_local() {
  require_compose

  # The workspace must not be the install dir (see the bootstrap guard for the
  # default; this catches an explicit DSH_WORKSPACE_DIR pointing there).
  ws_dir="$(norm_dir "${DSH_WORKSPACE_DIR:-$INVOKE_DIR}")"
  [ "$APP_DIR" != "$ws_dir" ] || fail \
    "DSH_WORKSPACE_DIR ($ws_dir) is the same as DSH_CONTAINER_DIR ($APP_DIR) — the workspace must not be the install dir (the settings .env would be read by the harness and refused)"

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
    echo "nothing installed yet — try:  curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh | sh -s -- local | server"
  fi
}

cmd_update() {
  require_compose
  which="${1:-auto}"
  [ "$#" -gt 0 ] && shift
  # `update` also refreshes the compose templates from upstream, so a new
  # template (or a fix like this one) reaches existing installs on update.
  info "refreshing project files in $APP_DIR"
  fetch_files
  if [ "$which" = "auto" ]; then
    if docker inspect dsh-server >/dev/null 2>&1; then which=server
    elif docker inspect dsh >/dev/null 2>&1; then which=local
    else fail "no stack is running — pass local or server explicitly"; fi
  fi
  case "$which" in
    local) docker_compose pull && docker_compose up -d ;;
    server) docker_compose $(server_args) pull && docker_compose $(server_args) up -d ;;
    *) fail "update takes local, server or auto (got: $which)" ;;
  esac
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
  curl -LsSf https://raw.githubusercontent.com/AndreasSeidl/dsh-docker/main/scripts/install.sh | sh -s -- <command>

  The installer downloads the project files into $DSH_CONTAINER_DIR
  (default ~/.dsh-container) and runs the stack from there. It never changes
  the directory you run it from (that stays your LOCAL workspace). If you want
  to control or modify the deployment yourself, use docker compose / docker run
  directly (see the README).

COMMANDS:
  local              LOCAL MODE — host dirs for harness data + workspace,
                     GUI on this machine only (127.0.0.1).
  server             SERVER MODE — persistent volumes for harness data +
                     workspaces, LAN/internet access by default (0.0.0.0).
  status             which stack is running and how to reach it.
  update [mode]      refresh templates, pull the newest image, restart
                     (mode: local|server|auto).
  uninstall [--purge] [mode]   stop; data kept unless --purge (deletes volumes).
  help               this message.

LOCAL DEFAULTS (override via env or edit the .env in DSH_CONTAINER_DIR):
  DSH_HOME_DIR=~/.dsh        harness data (settings, credentials, history)
  DSH_WORKSPACE_DIR=$PWD     the folder the agent works in
  DSH_BIND_ADDRESS=127.0.0.1 this machine only
  DSH_WEB_PORT=3080

SERVER DEFAULTS (override via env or edit the .env.server in DSH_CONTAINER_DIR):
  DSH_BIND_ADDRESS=0.0.0.0   published on every interface — remote access
  DSH_WEB_PORT=3080
  Volumes: dsh-server-home (/home/dsh/.dsh), dsh-server-workspaces (/workspaces)

INSTALL DIR:
  DSH_CONTAINER_DIR=~/.dsh-container   where the project files live
  DSH_CONTAINER_BASE_URL=...           mirror/fork base URL for the files

NOTES:
  The settings .env must never live IN the workspace: the harness reads an
  optional .env from the workspace and refuses DSH_* variables there (only the
  launching environment may set them) — the installer keeps its .env in
  DSH_CONTAINER_DIR (never mounted) and refuses an install dir that would be
  the workspace.

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

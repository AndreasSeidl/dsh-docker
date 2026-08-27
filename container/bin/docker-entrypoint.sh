#!/bin/sh
# Docker entrypoint for the DeepSeek Harness container.
#
# Maps container-friendly environment variables onto the `dsh web` flag family
# so that a plain `docker run ... dsh-image` behaves exactly like
# `pnpm dsh web`, while still letting a deployment configure every web-facing
# knob through the environment instead of editing image internals.
#
# Env vars consumed here (beyond the ones the harness itself reads straight
# from the process environment, which all pass through untouched):
#   DSH_WORKSPACE        Working directory the harness uses as its default
#                        workspace root (its process.cwd). Defaults to
#                        /workspace — the volume-backed agent workspace.
#   DSH_WEB_BIND         Listen host for the *public* endpoint. In the default
#                        faithful mode this is the harness listener
#                        ("127.0.0.1", default, same as `pnpm dsh web`;
#                        "0.0.0.0"/"all"/"::" binds every interface, applied
#                        via a `--patch` overlay because the harness rejects
#                        --host 0.0.0.0). In proxy mode (DSH_WEB_PROXY=1) it
#                        is the proxy's public bind (defaults to 0.0.0.0 so
#                        LAN/network access works out of the box).
#   DSH_WEB_PORT         Public listen port (default 3080, same as `pnpm dsh web`).
#   DSH_WEB_PROXY        Non-empty enables the bundled reverse proxy: the web
#                        app stays loopback-only on DSH_APP_PORT and the proxy
#                        publishes DSH_WEB_PORT on DSH_WEB_BIND, rewriting
#                        Host/Origin to loopback so the /api trust fence and
#                        the same-origin page both work over the network with
#                        no further config. Recommended for any deployment
#                        that is reached beyond the host. It is NOT an auth
#                        layer; it is the documented place to add one later.
#   DSH_APP_PORT         Loopback port the web app listens on in proxy mode
#                        (default 3081).
#   DSH_WEB_NO_OPEN      Non-empty (default) adds --no-open (containers have no
#                        browser). Set to 0 to allow the browser-handoff path.
#   DSH_WEB_TRUSTED_HOSTS  Space- or comma-separated authorities the /api trust
#                        fence should accept beyond loopback/container IPs, e.g.
#                        "dsh.example.com" or "host.internal:3080". In proxy
#                        mode the same variable becomes a Host allow-list at
#                        the proxy (requests from other Hosts get 403),
#                        restoring a DNS-rebinding fence in front of the app.
#   DSH_WEB_ARGS         Extra raw arguments appended after the mapped flags
#                        (must start with "-"; useful for exotic knobs).
#
# On the FIRST boot of an empty $DSH_HOME volume the entrypoint seeds default
# settings.yaml and AGENTS.md (the harness's fixed user-global instructions)
# from the image-provided copies under /opt/dsh/defaults. Existing files are
# never touched.
#
# Every other variable (DSH_HOME, DSH_TELEMETRY_DISABLED, DSH_TOOLS_MODE,
# DEEPSEEK_API_KEY, DEEPSEEK_BASE_URL, provider keys, HTTP(S)_PROXY, TZ, ...)
# is inherited straight into the process and the harness's layered environment.
set -eu

DSH_BIN=/usr/local/bin/dsh
DSH_HOME="${DSH_HOME:-/home/dsh/.dsh}"

# ── First-boot volume initialization ──────────────────────────────────────
# Idempotent: seeds scaffold files into an empty $DSH_HOME, never overwrites.
if [ -d "$DSH_HOME" ]; then
  for f in settings.yaml AGENTS.md; do
    if [ ! -e "$DSH_HOME/$f" ] && [ -f "/opt/dsh/defaults/$f" ]; then
      cp "/opt/dsh/defaults/$f" "$DSH_HOME/$f"
      echo "dsh: seeded default $f into $DSH_HOME" >&2
    fi
  done
  # pnpm's content-addressed store lives on the volume so plugin installs stay
  # fast and persistent; make sure it exists and is writable.
  mkdir -p "$DSH_HOME/.pnpm-store"
fi

# The invoking directory is the harness's default workspace root (the same
# rule as `pnpm dsh web`). In the container that is the workspace the user
# backs with a volume; relocate it with DSH_WORKSPACE.
workspace="${DSH_WORKSPACE:-/workspace}"
if [ ! -d "$workspace" ]; then
  echo "dsh: workspace '$workspace' does not exist (set DSH_WORKSPACE to an existing directory)" >&2
  exit 1
fi
cd "$workspace" || exit 1

# First positional selects the dsh mode. `web` (the default) gets the env
# mapping; anything else passes straight through — note we do NOT shift, every
# original argument has to reach the CLI (`dsh --version`, `dsh
# --profile headless "run"`, `dsh plugin ...`, `dsh --profile web
# --dump-default-config`).
mode="${1:-web}"
if [ "$mode" != "web" ]; then
  exec "$DSH_BIN" "$@"
fi
if [ "$#" -gt 0 ]; then shift; fi

# --no-open for containers (no default browser). Opt out with DSH_WEB_NO_OPEN=0.
no_open_args=""
if [ "${DSH_WEB_NO_OPEN:-1}" != "0" ]; then
  no_open_args="--no-open"
fi

# ── Proxy mode: harness loopback + bundled reverse proxy on the public port ──
if [ "${DSH_WEB_PROXY:-}" != "" ]; then
  app_port="${DSH_APP_PORT:-3081}"
  export DSH_APP_PORT="$app_port"
  echo "dsh: proxy mode — web app on 127.0.0.1:$app_port, public on \${DSH_WEB_BIND:-0.0.0.0}:\${DSH_WEB_PORT:-3080}" >&2
  # shellcheck disable=SC2086  # deliberate word-splitting of mapped flags
  exec /usr/local/bin/node /usr/local/lib/dsh-container/reverse-proxy.mjs \
    --port "$app_port" \
    $no_open_args \
    ${DSH_WEB_ARGS:-} \
    "$@"
fi

# ── Faithful mode: run dsh web directly, exactly like `pnpm dsh web` ───────
# The `web` subcommand owns a small launcher flag set of its own:
# --patch/--dump-config/--dump-default-config. Put --patch FIRST, right after
# `web`, so commander consumes it before the app's own (unknown-to-the-launcher)
# flags start, and everything after is passed through to the web app verbatim.
patch_args=""
bind="${DSH_WEB_BIND:-127.0.0.1}"
case "$bind" in
  ""|127.0.0.1|loopback|lo)
    bind="127.0.0.1"
    ;;
  0.0.0.0|all|any|::)
    bind="0.0.0.0"
    patch_file="${TMPDIR:-/tmp}/dsh-host-bind.patch.yml"
    cat > "$patch_file" <<EOF
# Generated by the dsh container entrypoint: bind the web server to all
# interfaces. The CLI rejects --host 0.0.0.0 for safety, so the bind is
# configured on the webserver row itself via this --patch overlay.
- id: webserver
  config:
    host: ${bind}
    port: !!js ctx.webStartup.port ?? ${DSH_WEB_PORT:-3080}
EOF
    patch_args="--patch ${patch_file}"
    ;;
  *)
    echo "dsh: unsupported DSH_WEB_BIND '${bind}' (use 127.0.0.1 or 0.0.0.0)" >&2
    exit 2
    ;;
esac

port_args=""
if [ -n "${DSH_WEB_PORT:-}" ]; then
  port_args="--port ${DSH_WEB_PORT}"
fi

trusted_args=""
trusted_hosts="${DSH_WEB_TRUSTED_HOSTS:-}"
if [ -n "$trusted_hosts" ]; then
  # Accept both space and comma separated lists; word-split each token.
  for host in $(printf '%s' "$trusted_hosts" | tr ',' ' '); do
    trusted_args="${trusted_args} --trusted-host ${host}"
  done
fi

# shellcheck disable=SC2086  # deliberate word-splitting of mapped flags
exec "$DSH_BIN" web \
  $patch_args \
  $no_open_args \
  $port_args \
  $trusted_args \
  ${DSH_WEB_ARGS:-} \
  "$@"
